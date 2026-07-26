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
    weak var playerView: MPVPlayerView?
    private let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
    private lazy var controller: AVPictureInPictureController = {
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: self
        )
        return AVPictureInPictureController(contentSource: source)
    }()
    private let frameProcessingQueue = DispatchQueue(
        label: "com.mpvplayerkit.picture-in-picture.frames",
        qos: .userInitiated
    )
    private let frameConverter = MPVPictureInPictureFrameConverter()
    private var frameTimer: DispatchSourceTimer?
    private var isCapturingFrame = false
    private var shouldStartAfterFirstFrame = false
    private var isStarting = false
    private var isStartCancellationRequested = false
    private var isTearingDown = false
    private var hasPostedActiveState = false
    private var consecutiveFrameCaptureFailures = 0
    private var frameCaptureGeneration: UInt64 = 0
    private var preferredRenderSize = CMVideoDimensions(width: 0, height: 0)
    private var playbackTimebase: CMTimebase?
    private var inlineCoverLifecycle = MPVPictureInPictureInlineCoverLifecycle()
    private let inlineCover = MPVPictureInPictureInlineCover()
    private let runtimeDiagnostics = MPVPictureInPictureRuntimeDiagnostics()
    private var hasLoggedFrameCaptureDeferral = false
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
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
        super.init()
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
        startFrameUpdates(every: .milliseconds(100))
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
        stopFrameUpdates()
        hideInlineCover()
        guard isActive || isStarting else { return }
        controller.stopPictureInPicture()
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
        startFrameUpdates(every: .milliseconds(100))
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
        preferredRenderSize = newRenderSize
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) {
        defer { completion() }
        guard let playerView else { return }
        let interval = MPVSystemPlaybackControls.fixedSkipInterval(
            requestedInterval: skipInterval.seconds
        )
        let target = MPVSystemPlaybackControls.seekTarget(
            currentTime: playerView.currentTime,
            duration: playerView.duration,
            offset: interval
        )
        guard playerView.seek(["time": target, "autoPlay": false] as NSDictionary) else {
            return
        }
        synchronizePlaybackTimebase(to: target)
        captureAndEnqueueFrame()
        invalidatePlaybackState()
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

    private func installSourceLayerIfNeeded() {
        guard let playerView else { return }
        installSourceLayer(in: playerView)
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
        ) == noErr, let timebase else { return }
        playbackTimebase = timebase
        sampleBufferDisplayLayer.controlTimebase = timebase
        synchronizePlaybackTimebase()
    }

    private func synchronizePlaybackTimebase(to time: TimeInterval? = nil) {
        guard let playbackTimebase, let playerView else { return }
        CMTimebaseSetTime(
            playbackTimebase,
            time: CMTime(seconds: max(0, time ?? playerView.currentTime), preferredTimescale: 600)
        )
        CMTimebaseSetRate(playbackTimebase, rate: playerView.isPlaying ? 1 : 0)
    }

    private func invalidatePlaybackState() {
        controller.invalidatePlaybackState()
    }

    private func startFrameUpdates(every interval: DispatchTimeInterval) {
        guard MPVPictureInPictureTeardownPolicy.shouldStartFrameUpdates(
            isTearingDown: isTearingDown
        ) else { return }
        stopFrameUpdates()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.captureAndEnqueueFrame() }
        }
        frameTimer = timer
        timer.resume()
    }

    private func stopFrameUpdates() {
        frameTimer?.setEventHandler {}
        frameTimer?.cancel()
        frameTimer = nil
        frameCaptureGeneration &+= 1
    }

    private func resumeAutomaticReadinessUpdates() {
        guard MPVPictureInPictureTeardownPolicy.shouldResumeAutomaticReadinessUpdates(
            allowsAutomaticStartFromInline: allowsAutomaticStartFromInline,
            isTearingDown: isTearingDown
        ) else { return }
        startFrameUpdates(every: .milliseconds(500))
    }

    private func captureAndEnqueueFrame() {
        guard isCapturingFrame == false, let playerView else { return }
        guard MPVPictureInPictureFrameCaptureReadiness.shouldCapture(
            hasValidVideoOutputParameters: playerView.hasPictureInPictureVideoOutputParameters,
            hasPlaybackOrReconfigurationSignal: playerView.hasPictureInPictureFirstVideoFrameSignal,
            isPlaying: playerView.isPlaying,
            isWaitingForStart: shouldStartAfterFirstFrame
        ) else {
            if hasLoggedFrameCaptureDeferral == false {
                hasLoggedFrameCaptureDeferral = true
                playerView.mpvDebugLog(
                    "pip capture deferred reason=video-not-ready "
                        + "outputParams=\(playerView.hasPictureInPictureVideoOutputParameters) "
                        + "firstFrameSignal=\(playerView.hasPictureInPictureFirstVideoFrameSignal)"
                )
            }
            return
        }
        hasLoggedFrameCaptureDeferral = false
        let generation = frameCaptureGeneration
        let frameProcessingQueue = frameProcessingQueue
        let frameConverter = frameConverter
        let preferredRenderSize = preferredRenderSize
        isCapturingFrame = true
        playerView.capturePictureInPictureFrame { [weak self] frame in
            frameProcessingQueue.async {
                let sampleBuffer = frame.flatMap {
                    frameConverter.makeSampleBuffer(from: $0, renderSize: preferredRenderSize)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isCapturingFrame = false
                    guard generation == self.frameCaptureGeneration else { return }
                    guard let frame, let sampleBuffer else {
                        self.handleFrameCaptureFailure()
                        return
                    }
                    self.consecutiveFrameCaptureFailures = 0
                    self.synchronizePlaybackTimebase(to: frame.presentationTime)
                    self.enqueue(sampleBuffer)
                    let wasWaitingForStart = self.shouldStartAfterFirstFrame
                    if wasWaitingForStart {
                        self.shouldStartAfterFirstFrame = false
                        guard MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
                            isStartCancellationRequested: self.isStartCancellationRequested,
                            isTearingDown: self.isTearingDown
                        ) else {
                            self.stopFrameUpdates()
                            self.resumeAutomaticReadinessUpdates()
                            return
                        }
                        self.isStarting = true
                        self.controller.startPictureInPicture()
                    }
                    if MPVPictureInPictureFrameUpdatePolicy.shouldKeepUpdating(
                        isActive: self.isActive,
                        isStarting: self.isStarting,
                        isWaitingForStart: self.shouldStartAfterFirstFrame
                    ) == false {
                        self.stopFrameUpdates()
                    }
                }
            }
        }
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if #available(iOS 17.0, *) {
            let renderer = sampleBufferDisplayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sampleBuffer)
        } else {
            if sampleBufferDisplayLayer.status == .failed { sampleBufferDisplayLayer.flush() }
            sampleBufferDisplayLayer.enqueue(sampleBuffer)
        }
    }

    private func handleFrameCaptureFailure() {
        consecutiveFrameCaptureFailures += 1
        guard consecutiveFrameCaptureFailures == 3 else { return }
        startFrameUpdates(every: .milliseconds(500))
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

public extension MPVPlayerView {
    @objc var isPictureInPictureSupported: Bool {
        pictureInPictureCoordinatorInstance != nil
    }

    @objc var isPictureInPictureActive: Bool {
        pictureInPictureCoordinator?.isActive == true
    }

    @objc var allowsAutomaticPictureInPictureFromInline: Bool {
        get { pictureInPictureCoordinator?.allowsAutomaticStartFromInline ?? false }
        set { pictureInPictureCoordinatorInstance?.allowsAutomaticStartFromInline = newValue }
    }

    @objc func startPictureInPicture() {
        MPVSystemPlaybackCoordinator.shared.activate(playerView: self)
        pictureInPictureCoordinatorInstance?.start()
    }

    @objc func stopPictureInPicture() {
        pictureInPictureCoordinator?.stop()
    }

    @objc func togglePictureInPicture() {
        isPictureInPictureActive ? stopPictureInPicture() : startPictureInPicture()
    }
}

extension MPVPlayerView {
    var pictureInPicturePreferredContentSize: CGSize {
        MPVPictureInPictureContentSize.resolve(videoDisplaySize: pictureInPictureVideoDisplaySize)
    }

    func resetPictureInPictureVideoOutputReadiness() {
        hasPictureInPictureVideoOutputParameters = false
        hasPictureInPictureFirstVideoFrameSignal = false
    }

    func updatePictureInPictureVideoDisplaySize(
        _ size: CGSize,
        signal: MPVPictureInPictureVideoOutputSignal = .none
    ) {
        let hasValidParameters = size.width > 0 && size.height > 0
        hasPictureInPictureVideoOutputParameters = hasValidParameters
        if hasValidParameters == false {
            hasPictureInPictureFirstVideoFrameSignal = false
        } else if signal.establishesFirstVideoFrameReadiness {
            hasPictureInPictureFirstVideoFrameSignal = true
        }
        let resolvedSize = MPVPictureInPictureContentSize.resolve(videoDisplaySize: size)
        guard pictureInPictureVideoDisplaySize != resolvedSize else { return }
        pictureInPictureVideoDisplaySize = resolvedSize
        pictureInPictureCoordinator?.playerVideoDisplaySizeDidChange()
    }

    func pictureInPictureViewHierarchyDidChange() {
        pictureInPictureCoordinator?.playerViewHierarchyDidChange()
    }

    func pictureInPictureViewDidLayout() {
        pictureInPictureCoordinator?.playerViewDidLayout()
    }

    func stopPictureInPictureForPlayerTeardown() {
        pictureInPictureCoordinator?.stopForPlayerTeardown()
    }

    private var pictureInPictureCoordinatorInstance: MPVPictureInPictureCoordinator? {
        if let pictureInPictureCoordinator { return pictureInPictureCoordinator }
        let coordinator = MPVPictureInPictureCoordinator(
            playerView: self,
            allowsAutomaticStartFromInline: false
        )
        pictureInPictureCoordinator = coordinator
        return coordinator
    }
}

enum MPVPictureInPictureVideoOutputSignal: Sendable {
    case none
    case fileLoaded
    case playbackRestart
    case videoReconfiguration

    var establishesFirstVideoFrameReadiness: Bool {
        switch self {
        case .playbackRestart, .videoReconfiguration:
            true
        case .none, .fileLoaded:
            false
        }
    }
}
