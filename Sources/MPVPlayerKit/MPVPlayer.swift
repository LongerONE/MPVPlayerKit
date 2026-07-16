import Foundation
import UIKit

public enum MPVPlaybackState: Int, Sendable {
    case buffering
    case readyToPlay
    case bufferFinished
    case paused
    case playedToTheEnd
    case error
}

public enum MPVDecoderMode: Int, Sendable {
    case initializing
    case hardware
    case software
}

public enum MPVVideoQuality: Int, Sendable {
    case powerSaving
    case balanced
    case highQuality
}

public enum MPVTemporalScaler: String, CaseIterable, Sendable {
    case oversample
    case linear
    case catmullRom = "catmull_rom"
    case mitchell
    case gaussian
    case bicubic
}

public enum MPVInterpolationQuality: Int, CaseIterable, Sendable {
    case off
    case standard
    case smooth
    case highQuality
}

public struct MPVInterpolationOptions: Equatable, Sendable {
    public var quality: MPVInterpolationQuality
    public var temporalScaler: MPVTemporalScaler
    public var threshold: Double
    public var blur: Double?
    public var clamp: Double
    public var radius: Double?
    public var antiring: Double

    public init(
        quality: MPVInterpolationQuality = .off,
        temporalScaler: MPVTemporalScaler? = nil,
        threshold: Double = 0.01,
        blur: Double? = nil,
        clamp: Double = 1.0,
        radius: Double? = nil,
        antiring: Double? = nil
    ) {
        self.quality = quality
        self.temporalScaler = temporalScaler ?? quality.defaultTemporalScaler
        self.threshold = threshold.isFinite ? min(max(threshold, -1.0), 1.0) : 0.01
        self.blur = blur.flatMap { $0.isFinite ? min(max($0, 0.5), 2.0) : nil }
        self.clamp = clamp.isFinite ? min(max(clamp, 0.0), 1.0) : 1.0
        self.radius = radius.flatMap { $0.isFinite ? min(max($0, 0.5), 16.0) : nil }
        self.antiring = antiring.map { $0.isFinite ? min(max($0, 0.0), 1.0) : quality.defaultAntiring }
            ?? quality.defaultAntiring
    }

    public static let off = MPVInterpolationOptions(quality: .off)
    public static let standard = MPVInterpolationOptions(quality: .standard)
    public static let smooth = MPVInterpolationOptions(quality: .smooth)
    public static let highQuality = MPVInterpolationOptions(quality: .highQuality)

    var bridgeValues: [String: Any] {
        var values: [String: Any] = [
            "interpolationQuality": NSNumber(value: quality.rawValue),
            "temporalScaler": temporalScaler.rawValue,
            "interpolationThreshold": NSNumber(value: threshold),
            "tscaleClamp": NSNumber(value: clamp),
            "tscaleAntiring": NSNumber(value: antiring),
        ]
        if let blur {
            values["tscaleBlur"] = NSNumber(value: blur)
        }
        if let radius {
            values["tscaleRadius"] = NSNumber(value: radius)
        }
        return values
    }

    init(bridgeDictionary values: NSDictionary) {
        let legacyEnabled = (values["smoothPlaybackEnabled"] as? NSNumber)?.boolValue ?? false
        let quality = (values["interpolationQuality"] as? NSNumber)
            .flatMap { MPVInterpolationQuality(rawValue: $0.intValue) }
            ?? (legacyEnabled ? .standard : .off)
        self.init(
            quality: quality,
            temporalScaler: (values["temporalScaler"] as? String).flatMap(MPVTemporalScaler.init(rawValue:)),
            threshold: (values["interpolationThreshold"] as? NSNumber)?.doubleValue ?? 0.01,
            blur: (values["tscaleBlur"] as? NSNumber)?.doubleValue,
            clamp: (values["tscaleClamp"] as? NSNumber)?.doubleValue ?? 1.0,
            radius: (values["tscaleRadius"] as? NSNumber)?.doubleValue,
            antiring: (values["tscaleAntiring"] as? NSNumber)?.doubleValue
        )
    }
}

public struct MPVSubtitleStyle: Equatable, Sendable {
    public var fontSize: Double
    public var bold: Bool
    public var textColor: String
    public var outlineSize: Double
    public var outlineColor: String
    public var shadowOffset: Double
    public var backgroundColor: String
    public var bottomOffset: Double

    public init(
        fontSize: Double = 38,
        bold: Bool = false,
        textColor: String = "#FFFFFFFF",
        outlineSize: Double = 0,
        outlineColor: String = "#FF000000",
        shadowOffset: Double = 0,
        backgroundColor: String = "#00000000",
        bottomOffset: Double = 34
    ) {
        self.fontSize = fontSize.isFinite ? min(max(fontSize, 8), 120) : 38
        self.bold = bold
        self.textColor = textColor
        self.outlineSize = outlineSize.isFinite ? min(max(outlineSize, 0), 10) : 0
        self.outlineColor = outlineColor
        self.shadowOffset = shadowOffset.isFinite ? min(max(shadowOffset, 0), 10) : 0
        self.backgroundColor = backgroundColor
        self.bottomOffset = bottomOffset.isFinite ? min(max(bottomOffset, 0), 300) : 34
    }

    public static let defaultStyle = MPVSubtitleStyle()
    public static let large = MPVSubtitleStyle(fontSize: 52, outlineSize: 1.5)
    public static let highContrast = MPVSubtitleStyle(
        fontSize: 42,
        bold: true,
        outlineSize: 2,
        shadowOffset: 1,
        backgroundColor: "#80000000"
    )

    var bridgeDictionary: NSDictionary {
        [
            "fontSize": NSNumber(value: fontSize),
            "bold": NSNumber(value: bold),
            "textColor": textColor,
            "outlineSize": NSNumber(value: outlineSize),
            "outlineColor": outlineColor,
            "shadowOffset": NSNumber(value: shadowOffset),
            "backgroundColor": backgroundColor,
            "bottomOffset": NSNumber(value: bottomOffset),
        ] as NSDictionary
    }
}

private extension MPVInterpolationQuality {
    var defaultTemporalScaler: MPVTemporalScaler {
        switch self {
        case .off, .standard: .oversample
        case .smooth: .linear
        case .highQuality: .mitchell
        }
    }

    var defaultAntiring: Double {
        self == .highQuality ? 0.6 : 0.0
    }
}

public enum MPVMediaTrackType: String, CaseIterable, Sendable {
    case video
    case audio
    case subtitle = "sub"
}

public struct MPVPlayerConfiguration: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var userAgent: String?
    public var forceSoftwareDecode: Bool
    public var isDolbyVisionPlayback: Bool
    public var videoQuality: MPVVideoQuality
    public var debandEnabled: Bool
    public var interpolationOptions: MPVInterpolationOptions
    public var smoothPlaybackEnabled: Bool {
        get { interpolationOptions.quality != .off }
        set { interpolationOptions = newValue ? .standard : .off }
    }

    public init(
        url: URL,
        headers: [String: String] = [:],
        userAgent: String? = nil,
        forceSoftwareDecode: Bool = false,
        isDolbyVisionPlayback: Bool = false,
        videoQuality: MPVVideoQuality = .balanced,
        debandEnabled: Bool = false,
        smoothPlaybackEnabled: Bool = false,
        interpolationOptions: MPVInterpolationOptions? = nil
    ) {
        self.url = url
        self.headers = headers
        self.userAgent = userAgent
        self.forceSoftwareDecode = forceSoftwareDecode
        self.isDolbyVisionPlayback = isDolbyVisionPlayback
        self.videoQuality = videoQuality
        self.debandEnabled = debandEnabled
        self.interpolationOptions = interpolationOptions ?? (smoothPlaybackEnabled ? .standard : .off)
    }

    var bridgeDictionary: NSDictionary {
        var values: [String: Any] = [
            "url": url.absoluteString,
            "headers": headers,
            "forceSoftwareDecode": NSNumber(value: forceSoftwareDecode),
            "isDolbyVisionPlayback": NSNumber(value: isDolbyVisionPlayback),
            "videoQuality": NSNumber(value: videoQuality.rawValue),
            "debandEnabled": NSNumber(value: debandEnabled),
            "smoothPlaybackEnabled": NSNumber(value: smoothPlaybackEnabled),
        ]
        values.merge(interpolationOptions.bridgeValues) { _, new in new }
        if let userAgent, userAgent.isEmpty == false {
            values["userAgent"] = userAgent
        }
        return values as NSDictionary
    }
}

public struct MPVMediaTrack: Identifiable, Equatable, Sendable {
    public let id: Int32
    public let type: MPVMediaTrackType
    public let name: String
    public let languageCode: String?
    public let codec: String
    public let bitRate: Int64
    public let isSelected: Bool
    public let isImageSubtitle: Bool

    init?(dictionary: NSDictionary) {
        guard let id = (dictionary["trackID"] as? NSNumber)?.int32Value,
              let rawType = dictionary["mpvType"] as? String,
              let type = MPVMediaTrackType(rawValue: rawType) else {
            return nil
        }
        self.id = id
        self.type = type
        self.name = dictionary["name"] as? String ?? "Track \(id)"
        self.languageCode = dictionary["languageCode"] as? String
        self.codec = dictionary["codec"] as? String ?? ""
        self.bitRate = (dictionary["bitRate"] as? NSNumber)?.int64Value ?? 0
        self.isSelected = (dictionary["isEnabled"] as? NSNumber)?.boolValue ?? false
        self.isImageSubtitle = (dictionary["isImageSubtitle"] as? NSNumber)?.boolValue ?? false
    }
}

@MainActor
public protocol MPVPlayerDelegate: AnyObject {
    func player(_ player: MPVPlayer, didChangeState state: MPVPlaybackState)
    func player(_ player: MPVPlayer, didUpdateCurrentTime currentTime: TimeInterval, duration: TimeInterval)
    func player(_ player: MPVPlayer, didUpdateBufferingProgress progress: Int)
    func player(_ player: MPVPlayer, didUpdateDecoderMode mode: MPVDecoderMode)
}

public extension MPVPlayerDelegate {
    func player(_ player: MPVPlayer, didChangeState state: MPVPlaybackState) {}
    func player(_ player: MPVPlayer, didUpdateCurrentTime currentTime: TimeInterval, duration: TimeInterval) {}
    func player(_ player: MPVPlayer, didUpdateBufferingProgress progress: Int) {}
    func player(_ player: MPVPlayer, didUpdateDecoderMode mode: MPVDecoderMode) {}
}

@MainActor
public final class MPVPlayer: NSObject {
    private struct PendingSubtitleLoad {
        let completion: (Bool) -> Void
        let timeout: DispatchWorkItem
    }

    public weak var delegate: MPVPlayerDelegate?
    public let playbackView: MPVPlayerView

    public var isPlaying: Bool { playbackView.isPlaying }
    public var duration: TimeInterval { playbackView.duration }
    public var currentTime: TimeInterval { playbackView.currentTime }
    public var contentMode: UIView.ContentMode {
        get { playbackView.playerContentMode }
        set { playbackView.playerContentMode = newValue }
    }

    private var observers: [NSObjectProtocol] = []
    private var pendingSubtitleLoads: [String: PendingSubtitleLoad] = [:]

    public init(configuration: MPVPlayerConfiguration) {
        playbackView = MPVPlayerView(frame: .zero)
        super.init()
        observePlaybackEvents()
        playbackView.configure(configuration.bridgeDictionary)
    }

    public convenience init(
        url: URL,
        headers: [String: String] = [:],
        userAgent: String? = nil
    ) {
        self.init(configuration: MPVPlayerConfiguration(
            url: url,
            headers: headers,
            userAgent: userAgent
        ))
    }

    isolated deinit {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        pendingSubtitleLoads.values.forEach { $0.timeout.cancel() }
        pendingSubtitleLoads.removeAll()
        playbackView.stop()
    }

    public func play() {
        playbackView.play()
    }

    public func pause() {
        playbackView.pause()
    }

    public func stop() {
        playbackView.stop()
    }

    @discardableResult
    public func seek(to time: TimeInterval, autoPlay: Bool = false) -> Bool {
        playbackView.seek([
            "time": NSNumber(value: max(0, time)),
            "autoPlay": NSNumber(value: autoPlay),
        ] as NSDictionary)
    }

    public func setPlaybackRate(_ rate: Double) {
        playbackView.updatePlayRate(NSNumber(value: rate))
    }

    public func updateVideoQuality(_ quality: MPVVideoQuality) {
        playbackView.updateVideoQuality(NSNumber(value: quality.rawValue))
    }

    public func updateVideoRenderOptions(
        debandEnabled: Bool,
        interpolationOptions: MPVInterpolationOptions
    ) {
        var values: [String: Any] = [
            "debandEnabled": NSNumber(value: debandEnabled),
            "smoothPlaybackEnabled": NSNumber(value: interpolationOptions.quality != .off),
        ]
        values.merge(interpolationOptions.bridgeValues) { _, new in new }
        playbackView.updateVideoRenderOptions(values as NSDictionary)
    }

    public func tracks(ofType type: MPVMediaTrackType) -> [MPVMediaTrack] {
        let values = playbackView.mediaTracks(["mediaType": type.rawValue] as NSDictionary)
        return values.compactMap { value in
            guard let dictionary = value as? NSDictionary else { return nil }
            return MPVMediaTrack(dictionary: dictionary)
        }
    }

    public func select(track: MPVMediaTrack) {
        playbackView.selectTrack([
            "trackID": NSNumber(value: track.id),
            "mediaType": track.type.rawValue,
            "isImageSubtitle": NSNumber(value: track.isImageSubtitle),
            "usesNativeSubtitleRendering": NSNumber(value: track.type == .subtitle && track.isImageSubtitle == false),
            "usesOriginalStyle": NSNumber(value: false),
        ] as NSDictionary)
    }

    public func setSubtitlesVisible(_ visible: Bool) {
        playbackView.setSubtitleVisible(["visible": NSNumber(value: visible)] as NSDictionary)
    }

    public func setSubtitleDelay(_ delay: TimeInterval) {
        playbackView.updateSubtitleDelay(NSNumber(value: delay))
    }

    @discardableResult
    public func loadExternalSubtitle(
        from url: URL,
        usesOriginalStyle: Bool = false,
        completion: @escaping (Bool) -> Void
    ) -> UUID {
        let requestID = UUID()
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishSubtitleLoad(requestID: requestID.uuidString, success: false)
        }
        pendingSubtitleLoads[requestID.uuidString] = PendingSubtitleLoad(
            completion: completion,
            timeout: timeout
        )
        playbackView.loadSubtitle([
            "requestID": requestID.uuidString,
            "url": url.absoluteString,
            "usesOriginalStyle": NSNumber(value: usesOriginalStyle),
        ] as NSDictionary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        return requestID
    }

    public func cancelExternalSubtitleLoad(_ requestID: UUID) {
        playbackView.cancelSubtitleLoad([
            "requestID": requestID.uuidString,
        ] as NSDictionary)
        finishSubtitleLoad(requestID: requestID.uuidString, success: false)
    }

    public func updateSubtitleStyle(_ style: MPVSubtitleStyle) {
        playbackView.updateSubtitleStyle(style.bridgeDictionary)
    }

    public func currentSubtitleText() -> String? {
        playbackView.currentSubtitleText() as String?
    }

    private func observePlaybackEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: MPVPlayerKitNotification.didChangeState,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            guard let rawValue = notification.userInfo?[MPVPlayerKitNotificationKey.state] as? Int,
                  let state = MPVPlaybackState(rawValue: rawValue) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.player(self, didChangeState: state)
            }
        })
        observers.append(center.addObserver(
            forName: MPVPlayerKitNotification.didUpdateTime,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            let currentTime = Self.doubleValue(
                notification.userInfo?[MPVPlayerKitNotificationKey.currentTime]
            )
            let duration = Self.doubleValue(
                notification.userInfo?[MPVPlayerKitNotificationKey.duration]
            )
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.player(self, didUpdateCurrentTime: currentTime, duration: duration)
            }
        })
        observers.append(center.addObserver(
            forName: MPVPlayerKitNotification.didUpdateBufferingProgress,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            let progress = (notification.userInfo?[MPVPlayerKitNotificationKey.bufferingProgress] as? NSNumber)?.intValue
                ?? notification.userInfo?[MPVPlayerKitNotificationKey.bufferingProgress] as? Int
                ?? 0
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.player(self, didUpdateBufferingProgress: progress)
            }
        })
        observers.append(center.addObserver(
            forName: MPVPlayerKitNotification.didUpdateDecoderMode,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            guard let rawValue = notification.userInfo?[MPVPlayerKitNotificationKey.decoderMode] as? Int,
                  let mode = MPVDecoderMode(rawValue: rawValue) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.player(self, didUpdateDecoderMode: mode)
            }
        })
        observers.append(center.addObserver(
            forName: MPVPlayerKitNotification.didLoadSubtitle,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            guard let requestID = notification.userInfo?[MPVPlayerKitNotificationKey.requestID] as? String else {
                return
            }
            let success = (notification.userInfo?[MPVPlayerKitNotificationKey.success] as? NSNumber)?.boolValue
                ?? notification.userInfo?[MPVPlayerKitNotificationKey.success] as? Bool
                ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finishSubtitleLoad(requestID: requestID, success: success)
            }
        })
    }

    private func finishSubtitleLoad(requestID: String, success: Bool) {
        guard let pending = pendingSubtitleLoads.removeValue(forKey: requestID) else { return }
        pending.timeout.cancel()
        pending.completion(success)
    }

    nonisolated private static func doubleValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return 0
    }
}
