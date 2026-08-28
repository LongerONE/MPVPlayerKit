import Foundation

extension MPVPlayerView {
    /// Removes only the persistent byte-range cache for the configured video.
    @objc public func clearPersistentVideoCache() -> Bool {
        guard let sourceURL = url, sourceURL.isFileURL == false else {
            mpvDebugLog("persistent cache clear skipped missing remote source")
            return false
        }

        persistentCacheContext?.setPersistenceEnabled(false)
        let cacheKey = persistentCacheContext?.cacheKey
            ?? MPVPersistentVideoCacheContext.makeCacheKey(
                sourceURL: sourceURL,
                headers: headers,
                userAgent: userAgent
            )
        let directoryURL = persistentCacheContext?.cacheDirectoryURL ?? Self.videoCacheDirectoryURL
        let entryURL = directoryURL.appendingPathComponent(cacheKey, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: entryURL)
            mpvDebugLog("persistent cache cleared key=\(cacheKey)")
            return true
        } catch CocoaError.fileNoSuchFile {
            mpvDebugLog("persistent cache clear skipped entry-missing key=\(cacheKey)")
            return true
        } catch {
            mpvDebugLog(
                "persistent cache clear failed key=\(cacheKey) error=\(error.localizedDescription)"
            )
            return false
        }
    }

    nonisolated func logEffectiveCacheSettings(reason: String) {
        let propertyNames = [
            MPVProperty.cache,
            MPVProperty.cacheSeconds,
            MPVProperty.cacheOnDisk,
            MPVProperty.demuxerCacheDirectory,
            MPVProperty.demuxerCacheTime,
        ]
        let properties = propertyNames.map { name in
            "\(name)=\(getString(name) ?? "<unavailable>")"
        }.joined(separator: " ")
        mpvDebugLog(
            "cache settings effective reason=\(reason) configuredEnabled=\(cacheConfiguration.isEnabled) "
                + "configuredSeconds=\(cacheConfiguration.duration) configuredOnDisk=\(cacheConfiguration.isDiskCacheEnabled) "
                + "properties=[\(properties)] persistentContext=\(persistentCacheContext != nil) "
                + "directory=\(Self.videoCacheDirectoryURL.path)"
        )
    }
}
