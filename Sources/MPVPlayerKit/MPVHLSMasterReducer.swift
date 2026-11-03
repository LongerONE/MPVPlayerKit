import Foundation

/// 限制复杂 master 的探测规模，同时保留选中变体关联的音轨和字幕组。
enum MPVHLSMasterReducer {
    private struct Entry {
        let tag: String
        let url: URL
        let attributes: [String: String]
        let height: Int
        let bandwidth: Int
        let codec: String
        let groupKey: String
    }

    static func reduce(_ playlist: String, baseURL: URL) -> String? {
        let lines = playlist.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "#EXTM3U" else { return nil }
        var headers = [String]()
        var media = [(String, [String: String])]()
        var variants = [Entry]()
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            if line.isEmpty { continue }
            if line == "#EXTM3U" || line == "#EXT-X-INDEPENDENT-SEGMENTS" || line.hasPrefix("#EXT-X-VERSION:") || line.hasPrefix("#EXT-X-START:") {
                headers.append(line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                media.append((line, MPVHLSMasterResolver.parseAttributes(from: line)))
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                guard index < lines.count else { return nil }
                let uri = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                index += 1
                guard !uri.isEmpty, !uri.hasPrefix("#"), let url = remoteURL(uri, baseURL: baseURL) else { return nil }
                let attrs = MPVHLSMasterResolver.parseAttributes(from: line)
                let parsedHeight = attrs["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) } ?? 0
                // 不可信清单中的异常尺寸不能让排序时的整数计算溢出。
                let height = min(max(0, parsedHeight), 16384)
                let codecs = (attrs["CODECS"] ?? "").lowercased()
                let codec = codecs.contains("avc1") || codecs.contains("avc3") ? "avc" :
                    (codecs.contains("dvh1") || codecs.contains("dvhe") ? "dolby" :
                     (codecs.contains("hvc1") || codecs.contains("hev1") ? "hevc" : "other"))
                var groupFields = ["AUDIO", "VIDEO", "SUBTITLES", "CLOSED-CAPTIONS"]
#if !targetEnvironment(simulator)
                // SDR 与 HDR 可能复用同一编码族，真机需分别保留其变体。
                groupFields.append("VIDEO-RANGE")
#endif
                let key = groupFields.map { attrs[$0] ?? "" }.joined(separator: "|")
                variants.append(Entry(tag: line, url: url, attributes: attrs, height: height,
                                      bandwidth: Int(attrs["BANDWIDTH"] ?? "0") ?? 0, codec: codec, groupKey: key))
            } else if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                continue
            } else if line.hasPrefix("#EXT") || !line.hasPrefix("#") {
                // 未识别的 master 标签可能影响 DRM、变量或重定向，保留原始清单。
                return nil
            }
        }
        guard variants.count > 12, !media.isEmpty else { return nil }
        let groups = Dictionary(grouping: variants, by: \.groupKey)
        var selected = [Entry]()
        for key in groups.keys.sorted() {
            guard let entries = groups[key] else { continue }
#if targetEnvironment(simulator)
            // 模拟器使用软件解码，优先 AVC 以避免 4K/HDR 使诊断不可用。
            let candidates = entries.contains(where: { $0.codec == "avc" }) ? entries.filter { $0.codec == "avc" } : entries
            let codecGroups = [candidates]
            let targetHeight = 720
#else
            // 真机保留不同编码族，使 HDR 等能力不被 AVC 选择覆盖。
            let codecGroups = Dictionary(grouping: entries, by: \.codec).keys.sorted().compactMap { codec in
                entries.filter { $0.codec == codec }
            }
            let targetHeight = 2160
#endif
            for candidates in codecGroups {
                guard let best = candidates.min(by: {
                    let left = abs($0.height - targetHeight), right = abs($1.height - targetHeight)
                    return left == right ? $0.bandwidth < $1.bandwidth : left < right
                }) else { continue }
                selected.append(best)
            }
        }
        guard !selected.isEmpty, selected.count < variants.count else { return nil }
        var referenced = Set<String>()
        for entry in selected {
            for (type, key) in [("AUDIO", "AUDIO"), ("VIDEO", "VIDEO"), ("SUBTITLES", "SUBTITLES"), ("CLOSED-CAPTIONS", "CLOSED-CAPTIONS")] {
                if let group = entry.attributes[key], group != "NONE" { referenced.insert(type + "|" + group) }
            }
        }
        var output = headers
        var included = Set<String>()
        for (line, attrs) in media {
            guard let type = attrs["TYPE"], let group = attrs["GROUP-ID"], referenced.contains(type + "|" + group) else { continue }
            if let uri = attrs["URI"] {
                guard line.contains("URI=\"\(uri)\""), let url = remoteURL(uri, baseURL: baseURL) else { return nil }
                output.append(line.replacingOccurrences(of: "URI=\"\(uri)\"", with: "URI=\"\(url.absoluteString)\""))
            } else {
                output.append(line)
            }
            included.insert(type + "|" + group)
        }
        // 缺少关联组时继续使用原 master，避免输出静音或丢字幕的清单。
        guard referenced.isSubset(of: included) else { return nil }
        for entry in selected {
            output.append(entry.tag)
            output.append(entry.url.absoluteString)
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func remoteURL(_ text: String, baseURL: URL) -> URL? {
        guard !text.contains("{$"), let url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}
