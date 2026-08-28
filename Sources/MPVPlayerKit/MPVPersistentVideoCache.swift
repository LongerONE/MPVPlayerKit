import CryptoKit
@preconcurrency import Foundation

#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#endif

private func mpvPersistentCacheLog(_ message: String) {
    #if DEBUG
    print("MPVPersistentVideoCache \(message)")
    #endif
}

final class MPVPersistentVideoCacheContext: @unchecked Sendable {
    let sourceURL: URL
    let headers: [String: String]
    let userAgent: String?
    let cacheDirectoryURL: URL
    let cacheKey: String
    private let stateLock = NSLock()
    private var persistenceEnabled = true

    init(
        sourceURL: URL,
        headers: [String: String],
        userAgent: String?,
        cacheDirectoryURL: URL
    ) {
        self.sourceURL = sourceURL
        self.headers = headers
        self.userAgent = userAgent
        self.cacheDirectoryURL = cacheDirectoryURL
        self.cacheKey = Self.makeCacheKey(
            sourceURL: sourceURL,
            headers: headers,
            userAgent: userAgent
        )
    }

    func makeStream() -> MPVPersistentVideoCacheStream? {
        MPVPersistentVideoCacheStream(
            context: self
        )
    }

    var isPersistenceEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return persistenceEnabled
    }

    func setPersistenceEnabled(_ enabled: Bool) {
        stateLock.lock()
        persistenceEnabled = enabled
        stateLock.unlock()
    }

    private static func makeCacheKey(
        sourceURL: URL,
        headers: [String: String],
        userAgent: String?
    ) -> String {
        var urlIdentity = sourceURL.absoluteString
        if var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) {
            let ignoredQueryKeys = Set(["api_key", "x-emby-token", "playsessionid"])
            components.queryItems = components.queryItems?.filter {
                ignoredQueryKeys.contains($0.name.lowercased()) == false
            }
            urlIdentity = components.url?.absoluteString ?? sourceURL.absoluteString
        }

        let headerIdentity = headers
            .filter { key, _ in
                let normalizedKey = key.lowercased()
                return normalizedKey != "authorization"
                    && normalizedKey != "x-emby-token"
                    && normalizedKey != "api_key"
            }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let identity = "url=\(urlIdentity)\nheaders=\(headerIdentity)\nuserAgent=\(userAgent ?? "")"
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class MPVPersistentVideoCacheStore: @unchecked Sendable {
    static let chunkSize: Int64 = 1024 * 1024

    let entryDirectoryURL: URL
    private let fileManager = FileManager.default
    private let fileLock = NSLock()
    private let lock = NSLock()
    private var totalSize: Int64?

    init?(directoryURL: URL, cacheKey: String) {
        entryDirectoryURL = directoryURL.appendingPathComponent(cacheKey, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: entryDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            mpvPersistentCacheLog(
                "directory create failed key=\(cacheKey) error=\(error.localizedDescription)"
            )
            return nil
        }

        if let value = try? String(contentsOf: metadataURL, encoding: .utf8),
           let value = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)),
           value >= 0 {
            totalSize = value
        }
    }

    var knownTotalSize: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return totalSize
    }

    func chunkURL(index: Int64) -> URL {
        entryDirectoryURL.appendingPathComponent("chunk-\(index).part")
    }

    func readChunk(index: Int64) -> Data? {
        fileLock.lock()
        defer { fileLock.unlock() }
        let url = chunkURL(index: index)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    func writeChunk(_ data: Data, index: Int64, totalSize: Int64?) -> Bool {
        fileLock.lock()
        defer { fileLock.unlock() }
        do {
            try data.write(to: chunkURL(index: index), options: .atomic)
            if let totalSize, totalSize >= 0 {
                setTotalSize(totalSize)
            }
            return true
        } catch {
            mpvPersistentCacheLog(
                "chunk write failed index=\(index) bytes=\(data.count) error=\(error.localizedDescription)"
            )
            return false
        }
    }

    private var metadataURL: URL {
        entryDirectoryURL.appendingPathComponent("metadata")
    }

    private func setTotalSize(_ value: Int64) {
        lock.lock()
        if totalSize == value {
            lock.unlock()
            return
        }
        totalSize = value
        lock.unlock()
        try? Data(String(value).utf8).write(to: metadataURL, options: .atomic)
    }
}

private final class MPVHTTPResponseBox: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedData: Data?
    private var storedResponse: URLResponse?
    private var storedError: Error?

    func complete(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        storedData = data
        storedResponse = response
        storedError = error
        lock.unlock()
        semaphore.signal()
    }

    func result() -> (Data?, URLResponse?, Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (storedData, storedResponse, storedError)
    }
}

final class MPVPersistentVideoCacheStream: @unchecked Sendable {
    private let context: MPVPersistentVideoCacheContext
    private let sourceURL: URL
    private let headers: [String: String]
    private let userAgent: String?
    private let store: MPVPersistentVideoCacheStore
    private let ioLock = NSLock()
    private let stateLock = NSLock()
    private var position: Int64 = 0
    private var isCancelled = false
    private var activeTask: URLSessionDataTask?

    init?(
        context: MPVPersistentVideoCacheContext
    ) {
        guard let store = MPVPersistentVideoCacheStore(
            directoryURL: context.cacheDirectoryURL,
            cacheKey: context.cacheKey
        ) else {
            return nil
        }
        self.context = context
        self.sourceURL = context.sourceURL
        self.headers = context.headers
        self.userAgent = context.userAgent
        self.store = store
        mpvPersistentCacheLog(
            "stream opened key=\(context.cacheKey) knownSize=\(store.knownTotalSize.map(String.init) ?? "unknown")"
        )
    }

    func read(into buffer: UnsafeMutablePointer<CChar>, count: UInt64) -> Int64 {
        guard count > 0, count <= UInt64(Int.max) else { return 0 }
        ioLock.lock()
        defer { ioLock.unlock() }

        var bytesRead = 0
        let requestedCount = Int(count)
        while bytesRead < requestedCount {
            if cancelled() {
                return bytesRead > 0 ? Int64(bytesRead) : -1
            }

            if let totalSize = store.knownTotalSize, position >= totalSize {
                break
            }

            let chunkIndex = position / MPVPersistentVideoCacheStore.chunkSize
            let chunkOffset = position % MPVPersistentVideoCacheStore.chunkSize
            guard let chunk = loadChunk(index: chunkIndex) else {
                return bytesRead > 0 ? Int64(bytesRead) : -1
            }

            let available = chunk.count - Int(chunkOffset)
            guard available > 0 else { break }
            let amount = min(available, requestedCount - bytesRead)
            chunk.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                buffer.advanced(by: bytesRead).update(
                    from: baseAddress.advanced(by: Int(chunkOffset)).assumingMemoryBound(to: CChar.self),
                    count: amount
                )
            }
            bytesRead += amount
            position += Int64(amount)
        }

        return Int64(bytesRead)
    }

    func seek(to offset: Int64) -> Int64 {
        guard offset >= 0 else { return Int64(MPV_ERROR_GENERIC.rawValue) }
        ioLock.lock()
        position = offset
        ioLock.unlock()
        return offset
    }

    func size() -> Int64 {
        store.knownTotalSize ?? Int64(MPV_ERROR_UNSUPPORTED.rawValue)
    }

    func close() {
        cancel()
        mpvPersistentCacheLog(
            "stream closed cachedBytes=\(cachedByteCount()) knownSize=\(store.knownTotalSize.map(String.init) ?? "unknown")"
        )
    }

    func cancel() {
        stateLock.lock()
        isCancelled = true
        let task = activeTask
        activeTask = nil
        stateLock.unlock()
        task?.cancel()
    }

    private func loadChunk(index: Int64) -> Data? {
        if context.isPersistenceEnabled,
           let cached = store.readChunk(index: index) {
            mpvPersistentCacheLog("chunk hit index=\(index) bytes=\(cached.count)")
            return cached
        }

        mpvPersistentCacheLog(
            "chunk \(context.isPersistenceEnabled ? "miss" : "bypass") index=\(index) position=\(position)"
        )
        guard let fetched = fetchChunk(index: index, shouldStore: context.isPersistenceEnabled) else {
            mpvPersistentCacheLog("chunk fetch failed index=\(index)")
            return nil
        }
        return fetched
    }

    private func fetchChunk(index: Int64, shouldStore: Bool) -> Data? {
        let start = index * MPVPersistentVideoCacheStore.chunkSize
        if let totalSize = store.knownTotalSize, start >= totalSize {
            return Data()
        }
        let requestedEnd = start + MPVPersistentVideoCacheStore.chunkSize - 1
        var request = URLRequest(url: sourceURL)
        request.setValue("bytes=\(start)-\(requestedEnd)", forHTTPHeaderField: "Range")
        headers.forEach { key, value in request.setValue(value, forHTTPHeaderField: key) }
        if let userAgent,
           headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) == false {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let box = MPVHTTPResponseBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.complete(data: data, response: response, error: error)
        }
        stateLock.lock()
        if isCancelled {
            stateLock.unlock()
            task.cancel()
            return nil
        }
        activeTask = task
        stateLock.unlock()
        task.resume()

        while box.semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if cancelled() {
                task.cancel()
                clearActiveTask(task)
                return nil
            }
        }
        clearActiveTask(task)

        let (data, response, error) = box.result()
        if let error {
            mpvPersistentCacheLog("http error index=\(index) error=\(error.localizedDescription)")
            return nil
        }
        guard let httpResponse = response as? HTTPURLResponse,
              let data else {
            mpvPersistentCacheLog("http invalid response index=\(index)")
            return nil
        }

        let contentRange = Self.parseContentRange(httpResponse.value(forHTTPHeaderField: "Content-Range"))
        if httpResponse.statusCode == 416, let totalSize = contentRange?.total {
            if shouldStore {
                _ = store.writeChunk(Data(), index: index, totalSize: totalSize)
            }
            return Data()
        }
        guard httpResponse.statusCode == 206 || (httpResponse.statusCode == 200 && start == 0) else {
            mpvPersistentCacheLog("http status=\(httpResponse.statusCode) index=\(index)")
            return nil
        }
        let totalSize = contentRange?.total
            ?? (httpResponse.statusCode == 200
                ? httpResponse.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
                : nil)
        if httpResponse.statusCode == 206 {
            guard let contentRange,
                  contentRange.start == start,
                  contentRange.end >= contentRange.start else {
                mpvPersistentCacheLog(
                    "http range mismatch expected=\(start) actual=\(contentRange?.start.description ?? "unknown")"
                )
                return nil
            }
        }

        let expectedLength = totalSize.map {
            min(
                MPVPersistentVideoCacheStore.chunkSize,
                max(0, $0 - start)
            )
        } ?? MPVPersistentVideoCacheStore.chunkSize
        let chunkData = data.prefix(Int(expectedLength))
        let resolvedTotalSize = totalSize
            ?? (data.count < Int(expectedLength) ? start + Int64(data.count) : nil)

        guard chunkData.isEmpty == false || resolvedTotalSize == start else {
            mpvPersistentCacheLog("http empty data index=\(index)")
            return nil
        }
        if let resolvedTotalSize,
           resolvedTotalSize > start + Int64(chunkData.count),
           chunkData.count < Int(expectedLength) {
            mpvPersistentCacheLog(
                "http partial chunk index=\(index) bytes=\(chunkData.count) expected=\(expectedLength)"
            )
            return nil
        }
        if shouldStore {
            guard store.writeChunk(Data(chunkData), index: index, totalSize: resolvedTotalSize) else {
                return nil
            }
        }
        mpvPersistentCacheLog(
            "chunk stored index=\(index) bytes=\(chunkData.count) total=\(resolvedTotalSize.map(String.init) ?? "unknown")"
        )
        return Data(chunkData)
    }

    private func cachedByteCount() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: store.entryDirectoryURL,
            includingPropertiesForKeys: [.fileAllocatedSizeKey]
        ) else { return 0 }
        return enumerator.reduce(into: Int64(0)) { total, value in
            guard let url = value as? URL else { return }
            total += Int64((try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
        }
    }

    private func cancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCancelled
    }

    private func clearActiveTask(_ task: URLSessionDataTask) {
        stateLock.lock()
        if activeTask === task {
            activeTask = nil
        }
        stateLock.unlock()
    }

    private static func parseContentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = normalized.firstIndex(of: " ") else { return nil }
        let unit = normalized[..<separator]
        guard unit.caseInsensitiveCompare("bytes") == .orderedSame else { return nil }
        let rangeValue = normalized[normalized.index(after: separator)...]
        let parts = rangeValue.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        if parts[0] == "*" {
            guard let total = Int64(parts[1]) else { return nil }
            return (-1, -1, total)
        }
        let bounds = parts[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]) else { return nil }
        let total = parts[1] == "*" ? nil : Int64(parts[1])
        return (start, end, total)
    }
}

func mpvPersistentVideoCacheOpen(
    _ userData: UnsafeMutableRawPointer?,
    _ uri: UnsafeMutablePointer<CChar>?,
    _ info: UnsafeMutablePointer<mpv_stream_cb_info>?
) -> Int32 {
    guard let userData,
          let info,
          let stream = Unmanaged<MPVPersistentVideoCacheContext>
              .fromOpaque(userData)
              .takeUnretainedValue()
              .makeStream() else {
        return MPV_ERROR_LOADING_FAILED.rawValue
    }

    info.pointee.cookie = Unmanaged.passRetained(stream).toOpaque()
    info.pointee.read_fn = mpvPersistentVideoCacheRead
    info.pointee.seek_fn = mpvPersistentVideoCacheSeek
    info.pointee.size_fn = mpvPersistentVideoCacheSize
    info.pointee.close_fn = mpvPersistentVideoCacheClose
    info.pointee.cancel_fn = mpvPersistentVideoCacheCancel
    return 0
}

private func mpvPersistentVideoCacheRead(
    _ cookie: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ size: UInt64
) -> Int64 {
    guard let cookie, let buffer else { return -1 }
    return Unmanaged<MPVPersistentVideoCacheStream>
        .fromOpaque(cookie)
        .takeUnretainedValue()
        .read(into: buffer, count: size)
}

private func mpvPersistentVideoCacheSeek(
    _ cookie: UnsafeMutableRawPointer?,
    _ offset: Int64
) -> Int64 {
    guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
    return Unmanaged<MPVPersistentVideoCacheStream>
        .fromOpaque(cookie)
        .takeUnretainedValue()
        .seek(to: offset)
}

private func mpvPersistentVideoCacheSize(_ cookie: UnsafeMutableRawPointer?) -> Int64 {
    guard let cookie else { return Int64(MPV_ERROR_GENERIC.rawValue) }
    return Unmanaged<MPVPersistentVideoCacheStream>
        .fromOpaque(cookie)
        .takeUnretainedValue()
        .size()
}

private func mpvPersistentVideoCacheClose(_ cookie: UnsafeMutableRawPointer?) {
    guard let cookie else { return }
    let stream = Unmanaged<MPVPersistentVideoCacheStream>
        .fromOpaque(cookie)
        .takeRetainedValue()
    stream.close()
}

private func mpvPersistentVideoCacheCancel(_ cookie: UnsafeMutableRawPointer?) {
    guard let cookie else { return }
    Unmanaged<MPVPersistentVideoCacheStream>
        .fromOpaque(cookie)
        .takeUnretainedValue()
        .cancel()
}
