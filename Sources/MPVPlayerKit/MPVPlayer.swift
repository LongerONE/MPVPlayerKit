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
    public var smoothPlaybackEnabled: Bool

    public init(
        url: URL,
        headers: [String: String] = [:],
        userAgent: String? = nil,
        forceSoftwareDecode: Bool = false,
        isDolbyVisionPlayback: Bool = false,
        videoQuality: MPVVideoQuality = .balanced,
        debandEnabled: Bool = false,
        smoothPlaybackEnabled: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.userAgent = userAgent
        self.forceSoftwareDecode = forceSoftwareDecode
        self.isDolbyVisionPlayback = isDolbyVisionPlayback
        self.videoQuality = videoQuality
        self.debandEnabled = debandEnabled
        self.smoothPlaybackEnabled = smoothPlaybackEnabled
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

    deinit {
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

    public func loadExternalSubtitle(
        from url: URL,
        usesOriginalStyle: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        let requestID = UUID().uuidString
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishSubtitleLoad(requestID: requestID, success: false)
        }
        pendingSubtitleLoads[requestID] = PendingSubtitleLoad(
            completion: completion,
            timeout: timeout
        )
        playbackView.loadSubtitle([
            "requestID": requestID,
            "url": url.absoluteString,
            "usesOriginalStyle": NSNumber(value: usesOriginalStyle),
        ] as NSDictionary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func observePlaybackEvents() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: MPVPlayerKitNotification.didChangeState,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let rawValue = notification.userInfo?[MPVPlayerKitNotificationKey.state] as? Int,
                  let state = MPVPlaybackState(rawValue: rawValue) else { return }
            self.delegate?.player(self, didChangeState: state)
        })
        observers.append(center.addObserver(
            forName: MPVPlayerKitNotification.didUpdateTime,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let currentTime = Self.doubleValue(
                notification.userInfo?[MPVPlayerKitNotificationKey.currentTime]
            )
            let duration = Self.doubleValue(
                notification.userInfo?[MPVPlayerKitNotificationKey.duration]
            )
            self.delegate?.player(self, didUpdateCurrentTime: currentTime, duration: duration)
        })
        observers.append(center.addObserver(
            forName: MPVPlayerKitNotification.didUpdateBufferingProgress,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let progress = (notification.userInfo?[MPVPlayerKitNotificationKey.bufferingProgress] as? NSNumber)?.intValue
                ?? notification.userInfo?[MPVPlayerKitNotificationKey.bufferingProgress] as? Int
                ?? 0
            self.delegate?.player(self, didUpdateBufferingProgress: progress)
        })
        observers.append(center.addObserver(
            forName: MPVPlayerKitNotification.didUpdateDecoderMode,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let rawValue = notification.userInfo?[MPVPlayerKitNotificationKey.decoderMode] as? Int,
                  let mode = MPVDecoderMode(rawValue: rawValue) else { return }
            self.delegate?.player(self, didUpdateDecoderMode: mode)
        })
        observers.append(center.addObserver(
            forName: MPVPlayerKitNotification.didLoadSubtitle,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let requestID = notification.userInfo?[MPVPlayerKitNotificationKey.requestID] as? String else {
                return
            }
            let success = (notification.userInfo?[MPVPlayerKitNotificationKey.success] as? NSNumber)?.boolValue
                ?? notification.userInfo?[MPVPlayerKitNotificationKey.success] as? Bool
                ?? false
            self.finishSubtitleLoad(requestID: requestID, success: success)
        })
    }

    private func finishSubtitleLoad(requestID: String, success: Bool) {
        guard let pending = pendingSubtitleLoads.removeValue(forKey: requestID) else { return }
        pending.timeout.cancel()
        pending.completion(success)
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let value = value as? Double { return value }
        return (value as? NSNumber)?.doubleValue ?? 0
    }
}
