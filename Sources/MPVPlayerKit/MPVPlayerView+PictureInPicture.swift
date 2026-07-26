import AVKit
import CoreMedia
import QuartzCore
import UIKit
@MainActor
final class MPVPictureInPictureCoordinator:
    NSObject,
    @preconcurrency AVPictureInPictureControllerDelegate,
    @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate
{
    /// Playback facts AVKit reads through the playback delegate. It only has to
    /// re-read them when one of them changes.
    private struct PlaybackStateSnapshot: Equatable {
        let isPlaying: Bool
        let duration: TimeInterval
        let speed: Double
    }

    weak var playerView: MPVPlayerView?
    let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
    private lazy var controller: AVPictureInPictureController = {
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: self
        )
        return AVPictureInPictureController(contentSource: source)
    }()
    let frameProcessingQueue = DispatchQueue(
        label: "com.mpvplayerkit.picture-in-picture.frames",
        qos: .userInitiated
    )
    let frameConverter = MPVPictureInPictureFrameConverter()
    var frameTimer: DispatchSourceTimer?
    var frameTimerInterval: TimeInterval?
    var isCapturingFrame = false
    var shouldStartAfterFirstFrame = false
    var isStarting = false
    var isStartCancellationRequested = false
    var isTearingDown = false
    var hasPostedActiveState = false
    var consecutiveFrameCaptureFailures = 0
    var frameCaptureGeneration: UInt64 = 0
    var displayedFrameRefreshToken: UInt64 = 0
    var capturedFrameCount: UInt64 = 0
    /// Bounded until AVKit reports the size of its window.
    var preferredRenderSize = MPVPictureInPictureRenderBudget.default
    var videoFrameRate: Double = 0
    var averageCaptureDuration: TimeInterval = 0
    var lastCapturedPresentationTime: TimeInterval?
    var hasLoggedFrameCaptureDeferral = false
    private var playbackTimebase: CMTimebase?
    private var lastPlaybackStateSnapshot: PlaybackStateSnapshot?
    private var inlineCoverLifecycle = MPVPictureInPictureInlineCoverLifecycle()
    private let inlineCover = MPVPictureInPictureInlineCover()
    private let runtimeDiagnostics = MPVPictureInPictureRuntimeDiagnostics()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    var allowsAutomaticStartFromInline: Bool {
        didSet {
            controller.canStartPictureInPictureAutomaticallyFromInline =
                allowsAutomaticStartFromInline
            if allowsAutomaticStartFromInline {
                resumeAutomaticReadinessUpdates()
            } else if isActive == false {
                stopFrameUpdates()
            }
        }
    }

    var isActive: Bool { controller.isPictureInPictureActive }
    init?(playerView: MPVPlayerView, allowsAutomaticStartFromInline: Bool) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        self.playerView = playerView
        self.allowsAutomaticStartFromInline = allowsAutomaticStartFromInline
        super.init()
        updateVideoGravity()
        configurePlaybackTimebase()
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline =
            allowsAutomaticStartFromInline
        installSourceLayer(in: playerView)
        runtimeDiagnostics.logInitialCapabilityIfNeeded(
            playerView: playerView,
            displayLayer: sampleBufferDisplayLayer
        )
        observePlaybackState(of: playerView)
    }
    deinit {
        if Thread.isMainThread {
            MainActor.assumeIsolated { [inlineCover] in
                inlineCover.hide()
            }
        } else {
            // Player teardown is normally main-actor isolated. Retain this
            // fallback for an unexpected final release off the main thread.
            Task { @MainActor [inlineCover] in
                inlineCover.hide()
            }
        }
        frameTimer?.setEventHandler {}
        frameTimer?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        // A coordinator can survive a normal player stop. A later explicit
        // PiP start is a new lifecycle and may resume its frame timer.
        isTearingDown = false
        guard isActive == false, isStarting == false, shouldStartAfterFirstFrame == false else { return }
        playerView?.mpvDebugLog(
            "pip start requested possible=\(controller.isPictureInPicturePossible)"
        )
        installSourceLayerIfNeeded()
        if let playerView {
            runtimeDiagnostics.logRendererState(
                stage: "start-requested",
                playerView: playerView,
                displayLayer: sampleBufferDisplayLayer
            )
        }
        isStartCancellationRequested = false
        shouldStartAfterFirstFrame = true
        hasLoggedFrameCaptureDeferral = false
        lastCapturedPresentationTime = nil
        capturedFrameCount = 0
        startFrameUpdates(every: MPVPictureInPictureCaptureCadence.minimumPlayingInterval)
        captureAndEnqueueFrame()
    }

    func stop() {
        if MPVPictureInPictureStartCancellationPolicy.shouldStopSystemController(
            isStarting: isStarting
        ) {
            isStartCancellationRequested = true
            shouldStartAfterFirstFrame = false
            stopFrameUpdates()
            hideInlineCover()
            controller.stopPictureInPicture()
            return
        }
        guard isActive else {
            hideInlineCover()
            shouldStartAfterFirstFrame = false
            stopFrameUpdates()
            resumeAutomaticReadinessUpdates()
            return
        }
        controller.stopPictureInPicture()
    }

    func stopForPlayerTeardown() {
        isTearingDown = true
        isStartCancellationRequested = true
        shouldStartAfterFirstFrame = false
        lastCapturedPresentationTime = nil
        stopFrameUpdates()
        cancelSampleBufferProbe()
        hideInlineCover()
        guard isActive || isStarting else { return }
        controller.stopPictureInPicture()
    }

    func startSystemController() {
        controller.startPictureInPicture()
    }

    func playerViewHierarchyDidChange() {
        installSourceLayerIfNeeded()
        guard let playerView else { return }
        inlineCover.bringToFrontIfVisible(over: playerView)
    }

    func playerViewDidLayout() {
        guard let playerView else { return }
        inlineCover.bringToFrontIfVisible(over: playerView)
    }

    func playerVideoDisplaySizeDidChange() {
        // The raw screenshot preserves this display aspect ratio. Its actual
        // pixel dimensions are pooled by the frame converter.
        installSourceLayerIfNeeded()
    }

    /// Keeps the Picture in Picture window on the fit/fill mode of the inline
    /// player instead of always letterboxing.
    func playerContentModeDidChange() {
        updateVideoGravity()
    }

    /// Playback rate, pause state or duration changed outside of AVKit.
    func playbackStateDidChange() {
        synchronizePlaybackTimebase()
        invalidatePlaybackStateIfNeeded()
        applyCaptureCadence()
    }

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
            isStartCancellationRequested: isStartCancellationRequested,
            isTearingDown: isTearingDown
        ) else {
            isStarting = false
            hideInlineCover()
            pictureInPictureController.stopPictureInPicture()
            return
        }
        isStarting = true
        inlineCoverLifecycle.requestStart()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
            isStartCancellationRequested: isStartCancellationRequested,
            isTearingDown: isTearingDown
        ) else {
            isStarting = false
            hideInlineCover()
            pictureInPictureController.stopPictureInPicture()
            return
        }
        guard inlineCoverLifecycle.didStart() else { return }
        isStarting = false
        updateVideoGravity()
        synchronizePlaybackTimebase()
        invalidatePlaybackState()
        hasPostedActiveState = true
        if let playerView {
            inlineCover.show(over: playerView)
        }
        postStateChange(isActive: true)
        if let playerView {
            runtimeDiagnostics.logRendererState(
                stage: "active",
                playerView: playerView,
                displayLayer: sampleBufferDisplayLayer
            )
            runtimeDiagnostics.logPerformanceMetrics(
                stage: "active",
                playerView: playerView,
                displayLayer: sampleBufferDisplayLayer
            )
        }
        if startSampleBufferProbeIfEnabled() == false {
            applyCaptureCadence(force: true)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        playerView?.mpvDebugLog(
            "pip start failed error=\(error.localizedDescription)"
        )
        let shouldPostInactiveState = MPVPictureInPictureStartCancellationPolicy
            .shouldPostInactiveState(
                hasPostedActiveState: hasPostedActiveState,
                isStartCancellationRequested: isStartCancellationRequested
            )
        isStarting = false
        isStartCancellationRequested = false
        shouldStartAfterFirstFrame = false
        stopFrameUpdates()
        cancelSampleBufferProbe()
        resumeAutomaticReadinessUpdates()
        hasPostedActiveState = false
        hideInlineCover()
        if shouldPostInactiveState {
            postStateChange(isActive: false)
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        let shouldPostInactiveState = MPVPictureInPictureStartCancellationPolicy
            .shouldPostInactiveState(
                hasPostedActiveState: hasPostedActiveState,
                isStartCancellationRequested: isStartCancellationRequested
            )
        isStarting = false
        isStartCancellationRequested = false
        shouldStartAfterFirstFrame = false
        stopFrameUpdates()
        cancelSampleBufferProbe()
        resumeAutomaticReadinessUpdates()
        hasPostedActiveState = false
        hideInlineCover()
        if shouldPostInactiveState {
            postStateChange(isActive: false)
        }
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
        if playing { playerView?.play() } else { playerView?.pause() }
        synchronizePlaybackTimebase()
        invalidatePlaybackState()
        applyCaptureCadence()
        refreshDisplayedFrame()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        MPVSystemPlaybackControls.timeRange(duration: playerView?.duration ?? 0)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        playerView?.isPlaying != true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        guard MPVPictureInPictureRenderBudget.isSignificantChange(
            from: preferredRenderSize,
            to: newRenderSize
        ) else { return }
        preferredRenderSize = newRenderSize
        playerView?.mpvDebugLog(
            "pip render size \(newRenderSize.width)x\(newRenderSize.height)"
        )
        captureAndEnqueueFrame(force: true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) {
        defer { completion() }
        guard let playerView else { return }
        let interval = MPVSystemPlaybackControls.resolvedSkipInterval(
            requestedInterval: skipInterval.seconds
        )
        guard interval != 0 else { return }
        // `MPVPlayerView.seek` publishes the requested position immediately, so
        // consecutive skips add up instead of restarting from a stale time.
        let target = MPVSystemPlaybackControls.seekTarget(
            currentTime: playerView.currentTime,
            duration: playerView.duration,
            offset: interval
        )
        playerView.mpvDebugLog("pip skip interval=\(interval) target=\(target)")
        guard playerView.seek(["time": target, "autoPlay": false] as NSDictionary) else {
            return
        }
        synchronizePlaybackTimebase(to: target)
        invalidatePlaybackState()
        refreshDisplayedFrame()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool { false }

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

    func installSourceLayerIfNeeded() {
        guard let playerView else { return }
        installSourceLayer(in: playerView)
    }

    private func updateVideoGravity() {
        let contentMode = playerView?.currentContentModeSnapshot() ?? .fit
        let videoGravity: AVLayerVideoGravity = contentMode == .fill
            ? .resizeAspectFill
            : .resizeAspect
        guard sampleBufferDisplayLayer.videoGravity != videoGravity else { return }
        sampleBufferDisplayLayer.videoGravity = videoGravity
    }

    private func observePlaybackState(of playerView: MPVPlayerView) {
        let center = NotificationCenter.default
        [MPVPlayerKitNotification.didChangeState, MPVPlayerKitNotification.didUpdateTime]
            .forEach { name in
                observers.append(center.addObserver(
                    forName: name,
                    object: playerView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.playbackStateDidChange()
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
        ) == noErr, let timebase else { return }
        playbackTimebase = timebase
        sampleBufferDisplayLayer.controlTimebase = timebase
        synchronizePlaybackTimebase()
    }

    /// AVKit derives the Picture in Picture playback progress from this
    /// timebase, so it carries the MPV position and the effective play rate.
    func synchronizePlaybackTimebase(to time: TimeInterval? = nil) {
        guard let playbackTimebase, let playerView else { return }
        CMTimebaseSetTime(
            playbackTimebase,
            time: CMTime(seconds: max(0, time ?? playerView.currentTime), preferredTimescale: 600)
        )
        CMTimebaseSetRate(
            playbackTimebase,
            rate: playerView.isPlaying ? effectivePlaybackSpeed : 0
        )
    }

    private var effectivePlaybackSpeed: Double {
        guard let speed = playerView?.playbackSpeed, speed.isFinite, speed > 0 else { return 1 }
        return speed
    }

    func invalidatePlaybackState() {
        lastPlaybackStateSnapshot = playbackStateSnapshot()
        controller.invalidatePlaybackState()
    }

    private func invalidatePlaybackStateIfNeeded() {
        let snapshot = playbackStateSnapshot()
        guard snapshot != lastPlaybackStateSnapshot else { return }
        lastPlaybackStateSnapshot = snapshot
        controller.invalidatePlaybackState()
    }

    private func playbackStateSnapshot() -> PlaybackStateSnapshot {
        PlaybackStateSnapshot(
            isPlaying: playerView?.isPlaying == true,
            duration: playerView?.duration ?? 0,
            speed: effectivePlaybackSpeed
        )
    }

    private func hideInlineCover() {
        _ = inlineCoverLifecycle.end()
        inlineCover.hide()
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
