import Foundation

/// Resolves Apple-style HLS master playlists to a single media playlist.
///
/// lavf's HLS demuxer stalls on multi-rendition masters (dozens of
/// AUTOSELECT audio/subtitle + variant playlists). Browsers pick one variant;
/// we do the same before `loadfile`.
enum MPVHLSMasterResolver: Sendable {
    struct Variant: Sendable {
        let url: URL
        let bandwidth: Int
        let width: Int
        let height: Int
        let isAVC: Bool
        let isHEVC: Bool
    }

    static func needsResolution(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        let text = url.absoluteString.lowercased()
        return url.pathExtension.lowercased() == "m3u8"
            || text.contains(".m3u8")
            || text.contains("m3u8?")
    }

    private final class ResolutionResult: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        let semaphore = DispatchSemaphore(value: 0)

        func store(_ url: URL) {
            lock.lock()
            self.url = url
            lock.unlock()
        }

        func value() -> URL? {
            lock.lock()
            defer { lock.unlock() }
            return url
        }
    }

    /// MPV 串行队列入口；停止播放时及时取消，不等完整网络超时。
    static func resolveMediaPlaylistSync(
        from masterURL: URL,
        session: URLSession = .shared,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> URL {
        guard needsResolution(masterURL), !shouldCancel() else { return masterURL }
        let result = ResolutionResult()
        var request = URLRequest(url: masterURL)
        request.timeoutInterval = 15
        request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { data, response, _ in
            defer { result.semaphore.signal() }
            guard let data else { return }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            let variants = parseVariants(in: text, baseURL: masterURL)
            guard let picked = pickVariant(from: variants) else { return }
            result.store(picked.url)
        }
        task.resume()
        let deadline = DispatchTime.now() + 15
        while !shouldCancel() {
            if result.semaphore.wait(timeout: min(deadline, .now() + .milliseconds(100))) == .success {
                return shouldCancel() ? masterURL : result.value() ?? masterURL
            }
            if DispatchTime.now() >= deadline { break }
        }
        task.cancel()
        return masterURL
    }

    /// Returns the master URL unchanged when it is already a media playlist
    /// or cannot be parsed. Returns a concrete variant playlist on success.
    static func resolveMediaPlaylist(
        from masterURL: URL,
        session: URLSession = .shared
    ) async -> URL {
        guard needsResolution(masterURL) else { return masterURL }
        do {
            var request = URLRequest(url: masterURL)
            request.timeoutInterval = 15
            request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return masterURL
            }
            let text = String(decoding: data, as: UTF8.self)
            let variants = parseVariants(in: text, baseURL: masterURL)
            guard variants.isEmpty == false else { return masterURL }
            guard let picked = pickVariant(from: variants) else { return masterURL }
            return picked.url
        } catch {
            return masterURL
        }
    }

    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Prefer AVC ≤720p for software decode, then AVC ≤1080p, then any ≤1080p.
    static func pickVariant(from variants: [Variant]) -> Variant? {
        let sorted = variants.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            return $0.bandwidth > $1.bandwidth
        }
        if let pick = sorted.first(where: { $0.isAVC && $0.height <= 720 }) { return pick }
        if let pick = sorted.first(where: { $0.isAVC && $0.height <= 1080 }) { return pick }
        if let pick = sorted.first(where: { $0.height <= 1080 }) { return pick }
        return sorted.first
    }

    static func parseVariants(in playlist: String, baseURL: URL) -> [Variant] {
        var variants: [Variant] = []
        let lines = playlist.split(whereSeparator: \.isNewline).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                index += 1
                continue
            }
            // I-FRAME entries keep URI= on the same line — skip them.
            if line.uppercased().contains("URI=") {
                index += 1
                continue
            }
            let attrs = parseAttributes(from: line)
            index += 1
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                index += 1
            }
            guard index < lines.count else { break }
            let uriLine = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            guard uriLine.isEmpty == false, uriLine.hasPrefix("#") == false else { continue }
            guard let resolved = URL(string: uriLine, relativeTo: baseURL)?.absoluteURL else { continue }
            let resolution = attrs["RESOLUTION"] ?? ""
            let parts = resolution.lowercased().split(separator: "x")
            let width = parts.first.flatMap { Int($0) } ?? 0
            let height = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            let codecs = (attrs["CODECS"] ?? "").lowercased()
            variants.append(
                Variant(
                    url: resolved,
                    bandwidth: Int(attrs["BANDWIDTH"] ?? attrs["AVERAGE-BANDWIDTH"] ?? "0") ?? 0,
                    width: width,
                    height: height,
                    isAVC: codecs.contains("avc1") || codecs.contains("avc3"),
                    isHEVC: codecs.contains("hvc1") || codecs.contains("hev1") || codecs.contains("dvh1")
                )
            )
        }
        return variants
    }

    private static func parseAttributes(from line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let body = line[line.index(after: colon)...]
        var result: [String: String] = [:]
        var current = ""
        var key = ""
        var readingKey = true
        var inQuotes = false
        for character in body {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }
            if character == "," && inQuotes == false {
                if readingKey == false {
                    result[key] = unquote(current.trimmingCharacters(in: .whitespaces))
                }
                current = ""
                readingKey = true
                key = ""
                continue
            }
            if character == "=" && readingKey && inQuotes == false {
                key = current.trimmingCharacters(in: .whitespaces)
                current = ""
                readingKey = false
                continue
            }
            current.append(character)
        }
        if readingKey == false {
            result[key] = unquote(current.trimmingCharacters(in: .whitespaces))
        }
        return result
    }

    private static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        return String(value.dropFirst().dropLast())
    }
}
