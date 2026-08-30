import Foundation

enum MPVCachePreferences {
    private static let enabledKey = "mpv_cache_enabled"
    private static let durationKey = "mpv_cache_duration"

    static var configuration: MPVCacheConfiguration {
        let defaults = UserDefaults.standard
        return MPVCacheConfiguration(
            isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
            duration: defaults.object(forKey: durationKey) as? Double
                ?? MPVCacheConfiguration.defaultDuration
        )
    }

    static func save(_ configuration: MPVCacheConfiguration) {
        let defaults = UserDefaults.standard
        defaults.set(configuration.isEnabled, forKey: enabledKey)
        defaults.set(configuration.duration, forKey: durationKey)
    }
}
