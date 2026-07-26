import AVKit
import CoreMedia
import QuartzCore

extension MPVPictureInPictureCoordinator {
    /// Reschedules the capture timer for the current playback state.
    ///
    /// - Parameter force: starts the timer when it is not running yet, which is
    ///   how a newly active Picture in Picture window begins capturing.
    func applyCaptureCadence(force: Bool = false) {
        guard force || frameTimer != nil else { return }
        let interval = MPVPictureInPictureCaptureCadence.interval(
            videoFrameRate: videoFrameRate,
            averageCaptureDuration: averageCaptureDuration,
            isPlaying: playerView?.isPlaying == true
        )
        guard MPVPictureInPictureCaptureCadence.shouldReschedule(
            currentInterval: frameTimer == nil ? nil : frameTimerInterval,
            nextInterval: interval
        ) else { return }
        startFrameUpdates(every: interval)
    }

    func startFrameUpdates(every interval: TimeInterval) {
        guard MPVPictureInPictureTeardownPolicy.shouldStartFrameUpdates(
            isTearingDown: isTearingDown
        ) else { return }
        stopFrameUpdates()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: MPVPictureInPictureCaptureCadence.dispatchInterval(interval),
            leeway: .milliseconds(5)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.captureAndEnqueueFrame() }
        }
        frameTimer = timer
        frameTimerInterval = interval
        timer.resume()
    }

    func stopFrameUpdates() {
        frameTimer?.setEventHandler {}
        frameTimer?.cancel()
        frameTimer = nil
        frameTimerInterval = nil
        frameCaptureGeneration &+= 1
    }

    func resumeAutomaticReadinessUpdates() {
        guard MPVPictureInPictureTeardownPolicy.shouldResumeAutomaticReadinessUpdates(
            allowsAutomaticStartFromInline: allowsAutomaticStartFromInline,
            isTearingDown: isTearingDown
        ) else { return }
        startFrameUpdates(every: MPVPictureInPictureCaptureCadence.pausedInterval)
    }

    /// MPV completes a seek asynchronously, so one capture can still return the
    /// previous frame. A short burst keeps a paused Picture in Picture window
    /// from showing the position it was seeked away from.
    func refreshDisplayedFrame() {
        displayedFrameRefreshToken &+= 1
        let token = displayedFrameRefreshToken
        captureAndEnqueueFrame(force: true)
        for delay in [0.12, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.displayedFrameRefreshToken == token,
                          self.isTearingDown == false,
                          self.isActive || self.isStarting || self.shouldStartAfterFirstFrame
                    else { return }
                    self.captureAndEnqueueFrame()
                }
            }
        }
    }

    /// - Parameter force: captures even when the paused window already shows
    ///   the current position, for changes that are not position based such as
    ///   a new render size.
    func captureAndEnqueueFrame(force: Bool = false) {
        guard isCapturingFrame == false, let playerView else { return }
        if force == false, MPVPictureInPictureCaptureCadence.shouldSkipPausedCapture(
            isPlaying: playerView.isPlaying,
            isWaitingForStart: shouldStartAfterFirstFrame,
            lastCapturedPresentationTime: lastCapturedPresentationTime,
            currentTime: playerView.currentTime
        ) {
            return
        }
        guard MPVPictureInPictureFrameCaptureReadiness.shouldCapture(
            hasValidVideoOutputParameters: playerView.hasPictureInPictureVideoOutputParameters,
            hasPlaybackOrReconfigurationSignal: playerView.hasPictureInPictureFirstVideoFrameSignal,
            isPlaying: playerView.isPlaying,
            isWaitingForStart: shouldStartAfterFirstFrame,
            isPictureInPictureActive: isActive
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
        let renderSize = MPVPictureInPictureRenderBudget.resolve(
            reportedRenderSize: preferredRenderSize
        )
        let startedAt = CACurrentMediaTime()
        isCapturingFrame = true
        playerView.capturePictureInPictureFrame(
            renderSize: renderSize,
            converter: frameConverter
        ) { [weak self] capture in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.finishFrameCapture(
                        capture: capture,
                        generation: generation,
                        startedAt: startedAt
                    )
                }
            }
        }
    }

    private func finishFrameCapture(
        capture: MPVPictureInPictureCapture?,
        generation: UInt64,
        startedAt: CFTimeInterval
    ) {
        isCapturingFrame = false
        let captureDuration = CACurrentMediaTime() - startedAt
        averageCaptureDuration = MPVPictureInPictureCaptureCadence.averageCaptureDuration(
            previousAverage: averageCaptureDuration,
            sample: captureDuration
        )
        guard generation == frameCaptureGeneration else { return }
        guard let capture else {
            handleFrameCaptureFailure()
            return
        }
        consecutiveFrameCaptureFailures = 0
        videoFrameRate = capture.videoFrameRate
        lastCapturedPresentationTime = capture.presentationTime
        synchronizePlaybackTimebase(to: capture.presentationTime)
        enqueue(capture.sampleBuffer)
        logCaptureStatisticsIfNeeded(capture, captureDuration: captureDuration)
        let wasWaitingForStart = shouldStartAfterFirstFrame
        if wasWaitingForStart {
            shouldStartAfterFirstFrame = false
            guard MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
                isStartCancellationRequested: isStartCancellationRequested,
                isTearingDown: isTearingDown
            ) else {
                stopFrameUpdates()
                resumeAutomaticReadinessUpdates()
                return
            }
            isStarting = true
            startSystemController()
        }
        guard MPVPictureInPictureFrameUpdatePolicy.shouldKeepUpdating(
            isActive: isActive,
            isStarting: isStarting,
            isWaitingForStart: shouldStartAfterFirstFrame
        ) else {
            stopFrameUpdates()
            return
        }
        applyCaptureCadence()
    }

    /// Reports what a capture actually costs, so the cadence can be judged
    /// against real screenshot and scaling times on device.
    private func logCaptureStatisticsIfNeeded(
        _ capture: MPVPictureInPictureCapture,
        captureDuration: TimeInterval
    ) {
        capturedFrameCount &+= 1
        let isFirstFrameOfLifecycle = capturedFrameCount == 1 || shouldStartAfterFirstFrame
        guard isFirstFrameOfLifecycle
            || capturedFrameCount % MPVPictureInPictureCaptureCadence.statisticsInterval == 0
        else { return }
        let milliseconds = { (value: TimeInterval) in
            String(format: "%.1f", value * 1000)
        }
        playerView?.mpvDebugLog(
            "pip capture stats frames=\(capturedFrameCount) "
                + "source=\(capture.sourceWidth)x\(capture.sourceHeight) "
                + "output=\(capture.outputWidth)x\(capture.outputHeight) "
                + "screenshot=\(milliseconds(capture.screenshotDuration))ms "
                + "convert=\(milliseconds(capture.conversionDuration))ms "
                + "total=\(milliseconds(captureDuration))ms "
                + "average=\(milliseconds(averageCaptureDuration))ms "
                + "interval=\(milliseconds(frameTimerInterval ?? 0))ms "
                + "sourceFPS=\(String(format: "%.2f", capture.videoFrameRate)) "
                + "subtitles=\(capture.hasSubtitleOverlay)"
        )
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
        startFrameUpdates(every: MPVPictureInPictureCaptureCadence.pausedInterval)
    }
}
