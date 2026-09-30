import Foundation

struct MPVPlaybackConfigurationSnapshot: Sendable {
    var url: URL? = nil
    var headers: [String: String] = [:]
    var userAgent: String? = nil
    var forceSoftwareDecode: Bool = false
    var isDolbyVisionPlayback: Bool = false
    var videoQualityPreset: MPVVideoQualityPreset = .balanced
    var debandEnabled: Bool = false
    var cacheConfiguration: MPVCacheConfiguration = .default
    var customSubtitleFontName: String? = nil
}

/// 主线程的配置镜像与 MPV 队列的已应用快照分别拥有明确的读写边界。
final class MPVPlaybackConfigurationState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = MPVPlaybackConfigurationSnapshot()

    func snapshot() -> MPVPlaybackConfigurationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set<Value>(_ key: WritableKeyPath<MPVPlaybackConfigurationSnapshot, Value>, _ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value[keyPath: key] = newValue
    }
}

extension MPVPlayerView {
    nonisolated func configurationValue<Value>(_ key: KeyPath<MPVPlaybackConfigurationSnapshot, Value>) -> Value {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            return queueConfiguration[keyPath: key]
        }
        return configurationState.snapshot()[keyPath: key]
    }

    nonisolated func setConfigurationValue<Value>(
        _ key: WritableKeyPath<MPVPlaybackConfigurationSnapshot, Value>, _ value: Value
    ) {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            queueConfiguration[keyPath: key] = value
        } else {
            configurationState.set(key, value)
        }
    }

    nonisolated var url: URL? {
        get { configurationValue(\.url) }
        set { setConfigurationValue(\.url, newValue) }
    }
    nonisolated var headers: [String: String] {
        get { configurationValue(\.headers) }
        set { setConfigurationValue(\.headers, newValue) }
    }
    nonisolated var userAgent: String? {
        get { configurationValue(\.userAgent) }
        set { setConfigurationValue(\.userAgent, newValue) }
    }
    nonisolated var forceSoftwareDecode: Bool {
        get { configurationValue(\.forceSoftwareDecode) }
        set { setConfigurationValue(\.forceSoftwareDecode, newValue) }
    }
    nonisolated var isDolbyVisionPlayback: Bool {
        get { configurationValue(\.isDolbyVisionPlayback) }
        set { setConfigurationValue(\.isDolbyVisionPlayback, newValue) }
    }
    nonisolated var videoQualityPreset: MPVVideoQualityPreset {
        get { configurationValue(\.videoQualityPreset) }
        set { setConfigurationValue(\.videoQualityPreset, newValue) }
    }
    nonisolated var debandEnabled: Bool {
        get { configurationValue(\.debandEnabled) }
        set { setConfigurationValue(\.debandEnabled, newValue) }
    }
    nonisolated var cacheConfiguration: MPVCacheConfiguration {
        get { configurationValue(\.cacheConfiguration) }
        set { setConfigurationValue(\.cacheConfiguration, newValue) }
    }
    nonisolated var customSubtitleFontName: String? {
        get { configurationValue(\.customSubtitleFontName) }
        set { setConfigurationValue(\.customSubtitleFontName, newValue) }
    }
}
