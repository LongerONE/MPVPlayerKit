import Foundation

/// QuickPlayer 缓存偏好（UserDefaults）。
/// - 注意：`MPVQuickPlayerViewController` 初始化时会用本配置**覆盖**
///   宿主传入的 `MPVPlayerConfiguration.cacheConfiguration`。
/// - 直接使用 `MPVPlayer` / `MPVPlayerView` 时，传入的 cacheConfiguration 生效。
/// - Temby 等宿主使用自有 MMKV 缓存键，与本 UserDefaults 键无运行时共享。
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
