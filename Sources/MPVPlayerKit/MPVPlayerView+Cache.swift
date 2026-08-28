import Foundation

extension MPVPlayerView {
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
