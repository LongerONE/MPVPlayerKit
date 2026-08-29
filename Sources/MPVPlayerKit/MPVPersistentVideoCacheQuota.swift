import Foundation

final class MPVPersistentVideoCacheQuotaManager: @unchecked Sendable {
    static let shared = MPVPersistentVideoCacheQuotaManager()

    private let lock = NSLock()
    private var protectedPaths = Set<String>()

    func withProtectedChunk<T>(_ url: URL, operation: () throws -> T) rethrows -> T {
        let path = url.standardizedFileURL.path
        lock.lock()
        protectedPaths.insert(path)
        defer {
            protectedPaths.remove(path)
            lock.unlock()
        }
        return try operation()
    }

    func enforce(rootURL: URL, limitBytes: Int64?) {
        guard let limitBytes, limitBytes >= 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .fileAllocatedSizeKey,
                .contentModificationDateKey,
            ]
        ) else {
            return
        }

        var candidates: [(url: URL, size: Int64, modifiedAt: Date)] = []
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "part",
                  url.lastPathComponent.hasPrefix("chunk-") else {
                continue
            }
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileAllocatedSizeKey, .contentModificationDateKey]
            ),
                  values.isRegularFile == true,
                  let allocatedSize = values.fileAllocatedSize,
                  let modifiedAt = values.contentModificationDate else {
                continue
            }
            let size = Int64(allocatedSize)
            totalBytes += size
            candidates.append((url, size, modifiedAt))
        }

        guard totalBytes > limitBytes else { return }
        candidates.sort { $0.modifiedAt < $1.modifiedAt }

        for candidate in candidates {
            guard totalBytes > limitBytes else { break }
            guard protectedPaths.contains(candidate.url.standardizedFileURL.path) == false else {
                continue
            }
            do {
                try fileManager.removeItem(at: candidate.url)
                totalBytes -= candidate.size
                mpvPersistentCacheLog(
                    "quota evicted file=\(candidate.url.lastPathComponent) bytes=\(candidate.size) remaining=\(totalBytes) limit=\(limitBytes)"
                )
            } catch {
                mpvPersistentCacheLog(
                    "quota eviction failed file=\(candidate.url.lastPathComponent) error=\(error.localizedDescription)"
                )
            }
        }
    }
}
