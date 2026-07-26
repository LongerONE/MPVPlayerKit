import Foundation
import UIKit

@MainActor
public protocol MPVPlayerDelegate: AnyObject {
    func player(_ player: MPVPlayer, didChangeState state: MPVPlaybackState)
    func player(_ player: MPVPlayer, didUpdateCurrentTime currentTime: TimeInterval, duration: TimeInterval)
    func player(_ player: MPVPlayer, didUpdateBufferingProgress progress: Int)
    func player(_ player: MPVPlayer, didUpdateDecoderMode mode: MPVDecoderMode)
    func player(_ player: MPVPlayer, didChangePictureInPictureActive isActive: Bool)
}

public extension MPVPlayerDelegate {
    func player(_ player: MPVPlayer, didChangeState state: MPVPlaybackState) {}
    func player(_ player: MPVPlayer, didUpdateCurrentTime currentTime: TimeInterval, duration: TimeInterval) {}
    func player(_ player: MPVPlayer, didUpdateBufferingProgress progress: Int) {}
    func player(_ player: MPVPlayer, didUpdateDecoderMode mode: MPVDecoderMode) {}
    func player(_ player: MPVPlayer, didChangePictureInPictureActive isActive: Bool) {}
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
    public var isPictureInPictureSupported: Bool {
        playbackView.isPictureInPictureSupported
    }
    public var isPictureInPictureActive: Bool {
        playbackView.isPictureInPictureActive
    }
    public var allowsAutomaticPictureInPictureFromInline: Bool {
        get { playbackView.allowsAutomaticPictureInPictureFromInline }
        set { playbackView.allowsAutomaticPictureInPictureFromInline = newValue }
    }
    /// Draws MPV subtitles into Picture in Picture frames, so the window shows
    /// the same image as the inline player. Enabled by default.
    public var drawsSubtitlesInPictureInPicture: Bool {
        get { playbackView.drawsSubtitlesInPictureInPicture }
        set { playbackView.drawsSubtitlesInPictureInPicture = newValue }
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

    public func startPictureInPicture() {
        playbackView.startPictureInPicture()
    }

    public func stopPictureInPicture() {
        playbackView.stopPictureInPicture()
    }

    public func togglePictureInPicture() {
        playbackView.togglePictureInPicture()
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

    public var clientSubtitleRenderer: any MPVSubtitleRenderer {
        playbackView.clientSubtitleRenderer
    }

    public func useClientSubtitleRenderer(_ renderer: any MPVSubtitleRenderer) {
        playbackView.useClientSubtitleRenderer(renderer)
    }

    public func selectClientSubtitle(_ document: MPVSubtitleDocument?) {
        playbackView.selectClientSubtitle(document)
    }

    public func clearClientSubtitle() {
        playbackView.clearClientSubtitle()
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
        let options = [
            "requestID": requestID.uuidString,
            "url": url.absoluteString,
            "usesOriginalStyle": NSNumber(value: usesOriginalStyle),
        ] as NSDictionary
        playbackView.loadSubtitle(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        return requestID
    }

    @discardableResult
    public func loadClientSubtitle(
        from url: URL,
        headers: [String: String] = [:],
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
            "usesOriginalStyle": NSNumber(value: false),
        ] as NSDictionary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        return requestID
    }

    public func cancelExternalSubtitleLoad(_ requestID: UUID) {
        playbackView.cancelClientSubtitleLoad([
            "requestID": requestID.uuidString,
        ] as NSDictionary)
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
            forName: MPVPlayerKitNotification.didChangePictureInPicture,
            object: playbackView,
            queue: .main
        ) { [weak self] notification in
            let isActive = (notification.userInfo?["isActive"] as? NSNumber)?.boolValue
                ?? notification.userInfo?["isActive"] as? Bool
                ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.player(self, didChangePictureInPictureActive: isActive)
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
