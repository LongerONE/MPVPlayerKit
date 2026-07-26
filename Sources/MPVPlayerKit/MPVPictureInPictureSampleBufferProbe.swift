import AVFoundation
import CoreMedia
import CoreVideo

#if DEBUG
/// A one-shot, BGRA-only renderer acceptance probe for the Phase-B PiP bridge.
///
/// This deliberately exercises the same `AVSampleBufferVideoRenderer` that
/// AVKit owns for PiP. It does *not* read from or alter MPV's renderer. The
/// probe is opt-in through `MPVPictureInPictureEnqueueProbe`, submits exactly
/// one second of uncompressed BGRA samples, and then gives ownership of the
/// display layer back to the normal screenshot path.
@available(iOS 17.0, *)
@MainActor
final class MPVPictureInPictureSampleBufferProbe {
    static let isEnabledDefaultsKey = "MPVPictureInPictureEnqueueProbe"

    private enum State: String {
        case idle
        case waitingForBaseline
        case submitting
        case waitingForMetrics
        case complete
    }

    private static let frameCount = 60
    private static let frameRate: CMTimeScale = 60

    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private let log: @MainActor @Sendable (String) -> Void
    private let completion: @MainActor @Sendable () -> Void

    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var baselineTimeout: DispatchWorkItem?
    private var readinessTimeout: DispatchWorkItem?
    private var postSubmissionGrace: DispatchWorkItem?
    private var metricsTimeout: DispatchWorkItem?
    private var submittedFrameCount = 0
    private var withheldFrameCount = 0
    private var state: State = .idle
    private var ownsAllEnqueuedData = false
    private var hasRequestedMediaData = false
    private var baselineMetrics: MetricsSnapshot?

    private static let readinessTimeoutInterval: DispatchTimeInterval = .seconds(2)
    private static let metricsTimeoutInterval: DispatchTimeInterval = .seconds(2)
    private static let postSubmissionGraceInterval: DispatchTimeInterval = .milliseconds(500)

    private struct MetricsSnapshot {
        let totalFrames: Int
        let droppedFrames: Int
        let corruptedFrames: Int
        let accumulatedFrameDelay: TimeInterval

        init(
            totalFrames: Int,
            droppedFrames: Int,
            corruptedFrames: Int,
            accumulatedFrameDelay: TimeInterval
        ) {
            self.totalFrames = totalFrames
            self.droppedFrames = droppedFrames
            self.corruptedFrames = corruptedFrames
            self.accumulatedFrameDelay = accumulatedFrameDelay
        }
    }

    /// A probe can only be enabled deliberately in a Debug build. Release
    /// builds never compile this type or its call sites.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: isEnabledDefaultsKey)
    }

    init?(
        displayLayer: AVSampleBufferDisplayLayer,
        log: @escaping @MainActor @Sendable (String) -> Void,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard #available(iOS 17.0, *), let timebase = displayLayer.controlTimebase else {
            return nil
        }
        self.renderer = displayLayer.sampleBufferRenderer
        self.timebase = timebase
        self.log = log
        self.completion = completion
    }

    /// Starts the experiment after PiP is active. Existing capture callbacks
    /// must be invalidated by the coordinator before calling this method.
    func start() {
        guard state == .idle else { return }
        guard makeResources() else {
            completeProbe(result: "resource-creation-failed")
            return
        }

        captureBaselineMetricsThenBeginSubmission()
    }

    /// Stops an interrupted Debug run. The completion is still delivered so
    /// the coordinator can restore its normal capture lifecycle if PiP stays
    /// active (for example, after an AVKit renderer failure).
    func cancel() {
        completeProbe(result: "cancelled submitted=\(submittedFrameCount) withheld=\(withheldFrameCount)")
    }

    private func makeResources() -> Bool {
        let attributes = MPVPictureInPictureCapabilityProbe.requiredPixelBufferAttributes(
            for: .bgra8,
            width: 64,
            height: 64
        )
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool
        else { return false }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            == kCVReturnSuccess, let pixelBuffer
        else { return false }

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription
        else { return false }

        pixelBufferPool = pool
        self.formatDescription = formatDescription
        return true
    }

    private func captureBaselineMetricsThenBeginSubmission() {
        state = .waitingForBaseline
        guard #available(iOS 17.4, *) else {
            beginSubmission(baseline: nil, baselineResult: "unavailable")
            return
        }

        scheduleBaselineTimeout()
        renderer.loadVideoPerformanceMetrics { [weak self] metrics in
            Task { @MainActor in
                guard let self, self.state == .waitingForBaseline else { return }
                self.baselineTimeout?.cancel()
                self.baselineTimeout = nil
                self.beginSubmission(
                    baseline: metrics.map(Self.metricsSnapshot),
                    baselineResult: metrics == nil ? "unavailable" : "captured"
                )
            }
        }
    }

    private func beginSubmission(
        baseline: MetricsSnapshot?,
        baselineResult: String
    ) {
        guard state == .waitingForBaseline else { return }
        baselineMetrics = baseline

        // The startup frame belongs to the normal screenshot path. Clearing it
        // establishes an empty, bounded queue owned by this probe. The final
        // flush happens only after the post-submission grace and metrics read.
        renderer.flush()
        ownsAllEnqueuedData = true
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 1)
        state = .submitting
        log(
            "[PiPProbe][ENQUEUE] stage=start format=bgra8 size=64x64 frames=60 fps=60 "
                + "baseline=\(baselineResult)"
        )

        scheduleReadinessTimeout()
        hasRequestedMediaData = true
        renderer.requestMediaDataWhenReady(on: .main) { [weak self] in
            Task { @MainActor in self?.submitAvailableFrames() }
        }
    }

    private func submitAvailableFrames() {
        guard state == .submitting else { return }
        guard renderer.status != .failed else {
            completeProbe(result: "renderer-failed \(rendererStateDescription())")
            return
        }
        while renderer.isReadyForMoreMediaData,
              submittedFrameCount < Self.frameCount
        {
            guard let sampleBuffer = makeSampleBuffer(frameIndex: submittedFrameCount) else {
                completeProbe(result: "sample-buffer-creation-failed index=\(submittedFrameCount)")
                return
            }
            renderer.enqueue(sampleBuffer)
            submittedFrameCount += 1
        }
        if submittedFrameCount == Self.frameCount {
            beginPostSubmissionGrace()
        } else {
            withheldFrameCount += 1
        }
    }

    /// Produces PTS 0, 1/60, …, 59/60. No DisplayImmediately attachment is
    /// set: the display layer's existing control timebase schedules every
    /// sample, which is the behaviour the final frame bridge requires.
    private func makeSampleBuffer(frameIndex: Int) -> CMSampleBuffer? {
        guard let pixelBufferPool, let formatDescription else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
            == kCVReturnSuccess, let pixelBuffer
        else { return nil }
        fill(pixelBuffer: pixelBuffer, frameIndex: frameIndex)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Self.frameRate),
            presentationTimeStamp: CMTime(value: CMTimeValue(frameIndex), timescale: Self.frameRate),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let result = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard result == noErr else { return nil }
        return sampleBuffer
    }

    private func fill(pixelBuffer: CVPixelBuffer, frameIndex: Int) {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixel = Self.testPixelComponents(frameIndex: frameIndex)
        for row in 0 ..< height {
            let rowStart = baseAddress.advanced(by: row * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< width {
                let offset = column * 4
                // kCVPixelFormatType_32BGRA uses B, G, R, A byte order.
                rowStart[offset] = pixel[0]
                rowStart[offset + 1] = pixel[1]
                rowStart[offset + 2] = pixel[2]
                rowStart[offset + 3] = Self.testAlpha
            }
        }
    }

    private func completeProbe(result: String) {
        guard state != .complete else { return }
        state = .complete
        cancelScheduledWork()
        stopRequestingMediaDataIfNeeded()

        // The final flush happens only after the post-submission grace and
        // post-submission metrics snapshot.
        if ownsAllEnqueuedData {
            renderer.flush()
        }
        ownsAllEnqueuedData = false
        log("[PiPProbe][ENQUEUE] stage=complete \(result)")
        completion()
    }

    private func obsoleteLoadMetrics(result: String) {
        guard #available(iOS 17.4, *) else {
            log("[PiPProbe][ENQUEUE] stage=complete \(result) metrics=unavailable")
            completion()
            return
        }
        renderer.loadVideoPerformanceMetrics { [log, completion] metrics in
            let message: String
            if let metrics {
                message = "[PiPProbe][ENQUEUE] stage=complete \(result) "
                    + "total=\(metrics.totalNumberOfFrames) "
                    + "dropped=\(metrics.numberOfDroppedFrames) "
                    + "corrupted=\(metrics.numberOfCorruptedFrames) "
                    + "delay=\(String(format: "%.6f", metrics.totalAccumulatedFrameDelay))"
            } else {
                message = "[PiPProbe][ENQUEUE] stage=complete \(result) metrics=unavailable"
            }
            Task { @MainActor in
                log(message)
                completion()
            }
        }
    }

    static func testPixelComponents(frameIndex: Int) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: frameIndex &* 17),
            UInt8(truncatingIfNeeded: frameIndex &* 29),
            UInt8(truncatingIfNeeded: frameIndex &* 47),
        ]
    }

    static let testAlpha: UInt8 = .max

    @available(iOS 17.4, *)
    private static func metricsSnapshot(
        _ metrics: AVVideoPerformanceMetrics
    ) -> MetricsSnapshot {
        MetricsSnapshot(
            totalFrames: metrics.totalNumberOfFrames,
            droppedFrames: metrics.numberOfDroppedFrames,
            corruptedFrames: metrics.numberOfCorruptedFrames,
            accumulatedFrameDelay: metrics.totalAccumulatedFrameDelay
        )
    }

    private func beginPostSubmissionGrace() {
        guard state == .submitting else { return }
        state = .waitingForMetrics
        stopRequestingMediaDataIfNeeded()
        readinessTimeout?.cancel()
        readinessTimeout = nil
        let grace = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.loadPostSubmissionMetrics() }
        }
        postSubmissionGrace = grace
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.postSubmissionGraceInterval,
            execute: grace
        )
    }

    private func loadPostSubmissionMetrics() {
        guard state == .waitingForMetrics else { return }
        guard #available(iOS 17.4, *) else {
            completeProbe(result: completedResult(postMetrics: nil))
            return
        }
        scheduleMetricsTimeout()
        renderer.loadVideoPerformanceMetrics { [weak self] metrics in
            Task { @MainActor in
                guard let self, self.state == .waitingForMetrics else { return }
                self.metricsTimeout?.cancel()
                self.metricsTimeout = nil
                self.completeProbe(result: self.completedResult(
                    postMetrics: metrics.map(Self.metricsSnapshot)
                ))
            }
        }
    }

    private func completedResult(postMetrics: MetricsSnapshot?) -> String {
        let metricsDescription: String
        if let postMetrics, let baselineMetrics {
            metricsDescription = "deltaTotal=\(postMetrics.totalFrames - baselineMetrics.totalFrames) "
                + "deltaDropped=\(postMetrics.droppedFrames - baselineMetrics.droppedFrames) "
                + "deltaCorrupted=\(postMetrics.corruptedFrames - baselineMetrics.corruptedFrames) "
                + "deltaDelay=\(String(format: "%.6f", postMetrics.accumulatedFrameDelay - baselineMetrics.accumulatedFrameDelay))"
        } else if let postMetrics {
            metricsDescription = "total=\(postMetrics.totalFrames) "
                + "dropped=\(postMetrics.droppedFrames) "
                + "corrupted=\(postMetrics.corruptedFrames) "
                + "delay=\(String(format: "%.6f", postMetrics.accumulatedFrameDelay))"
        } else {
            metricsDescription = "metrics=unavailable"
        }
        return "submitted=\(submittedFrameCount) withheld=\(withheldFrameCount) "
            + "\(metricsDescription) \(rendererStateDescription())"
    }

    private func scheduleBaselineTimeout() {
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .waitingForBaseline else { return }
                self.beginSubmission(baseline: nil, baselineResult: "timeout")
            }
        }
        baselineTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.metricsTimeoutInterval, execute: timeout)
    }

    private func scheduleReadinessTimeout() {
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .submitting else { return }
                self.completeProbe(
                    result: "readiness-timeout submitted=\(self.submittedFrameCount) "
                        + "withheld=\(self.withheldFrameCount) \(self.rendererStateDescription())"
                )
            }
        }
        readinessTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readinessTimeoutInterval, execute: timeout)
    }

    private func scheduleMetricsTimeout() {
        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .waitingForMetrics else { return }
                self.completeProbe(result: self.completedResult(postMetrics: nil) + " metrics-timeout")
            }
        }
        metricsTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.metricsTimeoutInterval, execute: timeout)
    }

    private func cancelScheduledWork() {
        [baselineTimeout, readinessTimeout, postSubmissionGrace, metricsTimeout].forEach {
            $0?.cancel()
        }
        baselineTimeout = nil
        readinessTimeout = nil
        postSubmissionGrace = nil
        metricsTimeout = nil
    }

    private func stopRequestingMediaDataIfNeeded() {
        guard hasRequestedMediaData else { return }
        renderer.stopRequestingMediaData()
        hasRequestedMediaData = false
    }

    private func rendererStateDescription() -> String {
        let error = renderer.error.map { error in
            let nsError = error as NSError
            return "\(nsError.domain):\(nsError.code)"
        } ?? "none"
        return "status=\(renderer.status.rawValue) error=\(error) "
            + "requiresFlush=\(renderer.requiresFlushToResumeDecoding)"
    }
}
#endif
