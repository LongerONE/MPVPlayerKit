import AVKit
import CoreMedia
import QuartzCore
import UIKit

enum MPVPictureInPicturePlaybackMath {
    static let skipInterval: TimeInterval = 15

    static func fixedSkipInterval(requestedInterval: TimeInterval) -> TimeInterval {
        guard requestedInterval != 0 else { return 0 }
        return requestedInterval < 0 ? -skipInterval : skipInterval
    }

    static func clampedSeekTime(
        currentTime: TimeInterval,
        duration: TimeInterval,
        interval: TimeInterval
    ) -> TimeInterval {
        let target = max(0, currentTime + interval)
        guard duration.isFinite, duration > 0 else { return target }
        return min(target, duration)
    }

    static func timeRange(duration: TimeInterval) -> CMTimeRange {
        guard duration.isFinite, duration > 0 else {
            return .invalid
        }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }
}

@MainActor
final class MPVPictureInPictureCoordinator:
    NSObject,
    @preconcurrency AVPictureInPictureControllerDelegate,
    @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate
{
    weak var playerView: MPVPlayerView?
    private let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
    private lazy var controller: AVPictureInPictureController = {
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: self
        )
        return AVPictureInPictureController(contentSource: source)
    }()
    private var frameTimer: DispatchSourceTimer?
    private var isCapturingFrame = false
    private var shouldStartAfterFirstFrame = false
    private var consecutiveFrameCaptureFailures = 0
    private var frameCaptureRequestSequence: UInt64 = 0
    private var playbackTimebase: CMTimebase?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    var allowsAutomaticStartFromInline: Bool {
        didSet {
            controller.canStartPictureInPictureAutomaticallyFromInline = allowsAutomaticStartFromInline
            if allowsAutomaticStartFromInline {
                startFrameUpdates(every: .milliseconds(500))
            } else if controller.isPictureInPictureActive == false {
                stopFrameUpdates()
            }
        }
    }

    var isActive: Bool {
        controller.isPictureInPictureActive
    }

    init?(playerView: MPVPlayerView, allowsAutomaticStartFromInline: Bool) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }

        self.playerView = playerView
        self.allowsAutomaticStartFromInline = allowsAutomaticStartFromInline
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
        super.init()
        configurePlaybackTimebase()
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = allowsAutomaticStartFromInline
        installSourceLayer(in: playerView)
        observePlaybackState(of: playerView)
    }

    deinit {
        frameTimer?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        playerView?.setInlinePlaybackCoveredForPictureInPicture(false)
    }

    func start() {
        guard controller.isPictureInPictureActive == false else { return }
        installSourceLayerIfNeeded()
        shouldStartAfterFirstFrame = true
        startFrameUpdates(every: .milliseconds(100))
        captureAndEnqueueFrame()
    }

    func stop() {
        guard controller.isPictureInPictureActive else {
            shouldStartAfterFirstFrame = false
            stopFrameUpdates()
            return
        }
        controller.stopPictureInPicture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        playerView?.setInlinePlaybackCoveredForPictureInPicture(true)
        startFrameUpdates(every: .milliseconds(100))
        postStateChange(isActive: true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        shouldStartAfterFirstFrame = false
        stopFrameUpdates()
        playerView?.setInlinePlaybackCoveredForPictureInPicture(false)
        resumeAutomaticReadinessUpdates()
        postStateChange(isActive: false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        stopFrameUpdates()
        playerView?.setInlinePlaybackCoveredForPictureInPicture(false)
        resumeAutomaticReadinessUpdates()
        postStateChange(isActive: false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        if playing {
            playerView?.play()
        } else {
            playerView?.pause()
        }
        synchronizePlaybackTimebase()
        invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        MPVPictureInPicturePlaybackMath.timeRange(duration: playerView?.duration ?? 0)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        playerView?.isPlaying != true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) {
        guard let playerView else {
            completion()
            return
        }
        let target = MPVPictureInPicturePlaybackMath.clampedSeekTime(
            currentTime: playerView.currentTime,
            duration: playerView.duration,
            interval: MPVPictureInPicturePlaybackMath.fixedSkipInterval(
                requestedInterval: skipInterval.seconds
            )
        )
        _ = playerView.seek([
            "time": target,
            "autoPlay": false,
        ])
        synchronizePlaybackTimebase(to: target)
        captureAndEnqueueFrame()
        invalidatePlaybackState()
        completion()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    private func installSourceLayer(in playerView: MPVPlayerView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleBufferDisplayLayer.frame = playerView.bounds
        sampleBufferDisplayLayer.backgroundColor = UIColor.black.cgColor
        if sampleBufferDisplayLayer.superlayer !== playerView.layer {
            playerView.layer.insertSublayer(sampleBufferDisplayLayer, below: playerView.metalLayer)
        }
        CATransaction.commit()
    }

    private func installSourceLayerIfNeeded() {
        guard let playerView else { return }
        installSourceLayer(in: playerView)
    }

    private func observePlaybackState(of playerView: MPVPlayerView) {
        let center = NotificationCenter.default
        [
            MPVPlayerKitNotification.didChangeState,
            MPVPlayerKitNotification.didUpdateTime,
        ].forEach { name in
            observers.append(center.addObserver(
                forName: name,
                object: playerView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.synchronizePlaybackTimebase()
                    self?.invalidatePlaybackState()
                }
            })
        }
    }

    private func configurePlaybackTimebase() {
        var timebase: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        ) == noErr, let timebase else {
            return
        }
        playbackTimebase = timebase
        sampleBufferDisplayLayer.controlTimebase = timebase
        synchronizePlaybackTimebase()
    }

    private func synchronizePlaybackTimebase(to time: TimeInterval? = nil) {
        guard let playbackTimebase, let playerView else { return }
        let currentTime = time ?? playerView.currentTime
        CMTimebaseSetTime(
            playbackTimebase,
            time: CMTime(
                seconds: max(0, currentTime),
                preferredTimescale: 600
            )
        )
        CMTimebaseSetRate(
            playbackTimebase,
            rate: playerView.isPlaying ? 1 : 0
        )
    }

    private func invalidatePlaybackState() {
        controller.invalidatePlaybackState()
    }

    private func startFrameUpdates(every interval: DispatchTimeInterval) {
        stopFrameUpdates()
        playerView?.mpvDebugLog(
            "pip coordinator timer=start interval=\(String(describing: interval)) "
                + "active=\(controller.isPictureInPictureActive) "
                + "automatic=\(allowsAutomaticStartFromInline)"
        )
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: interval,
            leeway: .milliseconds(25)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.captureAndEnqueueFrame()
            }
        }
        frameTimer = timer
        timer.resume()
    }

    private func stopFrameUpdates() {
        if frameTimer != nil {
            playerView?.mpvDebugLog("pip coordinator timer=stop")
        }
        frameTimer?.setEventHandler {}
        frameTimer?.cancel()
        frameTimer = nil
        isCapturingFrame = false
    }

    private func resumeAutomaticReadinessUpdates() {
        guard allowsAutomaticStartFromInline else { return }
        startFrameUpdates(every: .milliseconds(500))
    }

    private func captureAndEnqueueFrame() {
        guard isCapturingFrame == false, let playerView else { return }
        guard playerView.isPlaying || shouldStartAfterFirstFrame else { return }
        frameCaptureRequestSequence &+= 1
        let requestSequence = frameCaptureRequestSequence
        let shouldLog = requestSequence <= 10 || requestSequence.isMultiple(of: 30)
        if shouldLog {
            playerView.mpvDebugLog(
                "pip coordinator capture=request sequence=\(requestSequence) "
                    + "active=\(controller.isPictureInPictureActive) "
                    + "shouldStart=\(shouldStartAfterFirstFrame)"
            )
        }
        installSourceLayerIfNeeded()
        isCapturingFrame = true
        playerView.capturePictureInPictureFrame { [weak self] frame in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCapturingFrame = false
                if shouldLog {
                    self.playerView?.mpvDebugLog(
                        "pip coordinator capture=completion sequence=\(requestSequence) "
                            + "hasFrame=\(frame != nil)"
                    )
                }
                guard let frame, let sampleBuffer = frame.makeSampleBuffer() else {
                    self.handleFrameCaptureFailure()
                    return
                }
                self.handleFrameCaptureSuccess()
                self.synchronizePlaybackTimebase(to: frame.presentationTime)
                if #available(iOS 17.0, *) {
                    let renderer = self.sampleBufferDisplayLayer.sampleBufferRenderer
                    if renderer.status == .failed {
                        renderer.flush()
                    }
                    renderer.enqueue(sampleBuffer)
                } else {
                    if self.sampleBufferDisplayLayer.status == .failed {
                        self.sampleBufferDisplayLayer.flush()
                    }
                    self.sampleBufferDisplayLayer.enqueue(sampleBuffer)
                }
                if self.shouldStartAfterFirstFrame {
                    self.shouldStartAfterFirstFrame = false
                    self.controller.startPictureInPicture()
                }
            }
        }
    }

    private func handleFrameCaptureFailure() {
        consecutiveFrameCaptureFailures += 1
        guard consecutiveFrameCaptureFailures == 3 else { return }
        startFrameUpdates(every: .milliseconds(500))
    }

    private func handleFrameCaptureSuccess() {
        guard consecutiveFrameCaptureFailures > 0 else { return }
        consecutiveFrameCaptureFailures = 0
        if controller.isPictureInPictureActive {
            startFrameUpdates(every: .milliseconds(100))
        }
    }

    private func postStateChange(isActive: Bool) {
        guard let playerView else { return }
        NotificationCenter.default.post(
            name: MPVPlayerKitNotification.didChangePictureInPicture,
            object: playerView,
            userInfo: ["isActive": isActive]
        )
    }
}

public extension MPVPlayerView {
    /// Whether Picture in Picture is available on the current device.
    @objc var isPictureInPictureSupported: Bool {
        pictureInPictureCoordinatorInstance != nil
    }

    /// Whether the player is currently presented in Picture in Picture.
    @objc var isPictureInPictureActive: Bool {
        pictureInPictureCoordinator?.isActive == true
    }

    /// Lets the system automatically enter Picture in Picture when the app moves
    /// to the background while this player is visible.
    @objc var allowsAutomaticPictureInPictureFromInline: Bool {
        get {
            pictureInPictureCoordinator?.allowsAutomaticStartFromInline ?? false
        }
        set {
            pictureInPictureCoordinatorInstance?.allowsAutomaticStartFromInline = newValue
        }
    }

    /// Starts Picture in Picture. Call this directly from a user interaction.
    @objc func startPictureInPicture() {
        pictureInPictureCoordinatorInstance?.start()
    }

    /// Stops Picture in Picture and restores rendering to the inline player.
    @objc func stopPictureInPicture() {
        pictureInPictureCoordinator?.stop()
    }

    /// Starts or stops Picture in Picture according to the current state.
    @objc func togglePictureInPicture() {
        if isPictureInPictureActive {
            stopPictureInPicture()
        } else {
            startPictureInPicture()
        }
    }
}

extension MPVPlayerView {
    var pictureInPicturePreferredContentSize: CGSize {
        CGSize(width: 16, height: 9)
    }

    func setInlinePlaybackCoveredForPictureInPicture(_ covered: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if covered {
            pictureInPictureInlineCoverLayer.frame = bounds
            pictureInPictureInlineCoverLayer.backgroundColor = UIColor.black.cgColor
            if pictureInPictureInlineCoverLayer.superlayer !== layer {
                layer.addSublayer(pictureInPictureInlineCoverLayer)
            }
        } else {
            pictureInPictureInlineCoverLayer.removeFromSuperlayer()
        }
        CATransaction.commit()
    }

    private var pictureInPictureCoordinatorInstance: MPVPictureInPictureCoordinator? {
        if let pictureInPictureCoordinator {
            return pictureInPictureCoordinator
        }
        let coordinator = MPVPictureInPictureCoordinator(
            playerView: self,
            allowsAutomaticStartFromInline: false
        )
        pictureInPictureCoordinator = coordinator
        return coordinator
    }

    func displayMetalLayerForPictureInPicture(
        in containerLayer: CALayer,
        bounds: CGRect,
        scale: CGFloat
    ) {
        isRenderingInPictureInPicture = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if metalLayer.superlayer !== containerLayer {
            metalLayer.removeFromSuperlayer()
            containerLayer.addSublayer(metalLayer)
        }
        CATransaction.commit()
        updateMetalLayerGeometry(
            for: bounds,
            scale: scale,
            transitionReason: "picture-in-picture",
            animated: false
        )
    }

    func restoreMetalLayerAfterPictureInPicture() {
        guard isRenderingInPictureInPicture || metalLayer.superlayer !== layer else { return }
        isRenderingInPictureInPicture = false
        metalLayer.removeFromSuperlayer()
        layer.addSublayer(metalLayer)
        updateMetalLayerGeometry(
            for: CGRect(origin: .zero, size: bounds.size),
            scale: UIScreen.main.nativeScale,
            transitionReason: "picture-in-picture-restore",
            animated: false
        )
    }
}
