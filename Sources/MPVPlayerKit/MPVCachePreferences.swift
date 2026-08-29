import Foundation

enum MPVCachePreferences {
    private static let enabledKey = "mpv_cache_enabled"
    private static let durationKey = "mpv_cache_duration"
    private static let onDiskKey = "mpv_cache_on_disk"
    private static let diskLimitKey = "mpv_cache_disk_limit"

    static var configuration: MPVCacheConfiguration {
        let defaults = UserDefaults.standard
        return MPVCacheConfiguration(
            isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
            duration: defaults.object(forKey: durationKey) as? Double
                ?? MPVCacheConfiguration.defaultDuration,
            isDiskCacheEnabled: defaults.object(forKey: onDiskKey) as? Bool ?? false,
            diskCacheLimit: MPVCacheDiskLimit(
                rawValue: (defaults.object(forKey: diskLimitKey) as? NSNumber)?.intValue
                    ?? MPVCacheDiskLimit.defaultLimit.rawValue
            ) ?? .defaultLimit
        )
    }

    static func save(_ configuration: MPVCacheConfiguration) {
        let defaults = UserDefaults.standard
        defaults.set(configuration.isEnabled, forKey: enabledKey)
        defaults.set(configuration.duration, forKey: durationKey)
        defaults.set(configuration.isDiskCacheEnabled, forKey: onDiskKey)
        defaults.set(configuration.diskCacheLimit.rawValue, forKey: diskLimitKey)
    }
}
