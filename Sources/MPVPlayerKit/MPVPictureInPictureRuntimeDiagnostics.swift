import AVFoundation

/// Debug-only runtime evidence for the phase-B final-frame bridge.
///
/// The diagnostics only allocate small test buffers and read AVFoundation
/// state. They never enqueue a probe buffer or modify MPV's renderer.
@MainActor
final class MPVPictureInPictureRuntimeDiagnostics {
    #if DEBUG
    private let capabilityProbe = MPVPictureInPictureCapabilityProbe()
    private var hasLoggedCapability = false
    #endif

    /// Allocation probes are intentionally expensive enough to keep out of
    /// PiP start/active transitions. One coordinator owns one display layer,
    /// so a single snapshot is sufficient for its entire lifecycle.
    func logInitialCapabilityIfNeeded(
        playerView: MPVPlayerView,
        displayLayer: AVSampleBufferDisplayLayer
    ) {
        #if DEBUG
        guard hasLoggedCapability == false else { return }
        hasLoggedCapability = true
        let capability = capabilityProbe.probe(displayLayer: displayLayer)
        playerView.mpvDebugLog("[PiPProbe][CAPABILITY] stage=display-layer-created \(capability.diagnosticDescription)")
        #endif
    }

    /// Start and active transitions report only mutable renderer state. They
    /// must not allocate capability pools or change the video pipeline.
    func logRendererState(
        stage: String,
        playerView: MPVPlayerView,
        displayLayer: AVSampleBufferDisplayLayer
    ) {
        #if DEBUG
        if #available(iOS 17.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            playerView.mpvDebugLog(
                "[PiPProbe][STATE] stage=\(stage) renderer=\(renderer.status) "
                    + "requiresFlush=\(renderer.requiresFlushToResumeDecoding)"
            )
        } else {
            playerView.mpvDebugLog(
                "[PiPProbe][STATE] stage=\(stage) displayLayer=\(displayLayer.status)"
            )
        }
        #endif
    }

    func logPerformanceMetrics(
        stage: String,
        playerView: MPVPlayerView,
        displayLayer: AVSampleBufferDisplayLayer
    ) {
        #if DEBUG
        let playerTransfer = MPVPlayerViewWeakTransfer(playerView)
        capabilityProbe.loadPerformanceMetrics(from: displayLayer) { metrics in
            guard let playerView = playerTransfer.value else { return }
            guard let metrics else {
                playerView.mpvDebugLog("[PiPProbe][METRICS] stage=\(stage) result=unavailable")
                return
            }
            playerView.mpvDebugLog(
                "[PiPProbe][METRICS] stage=\(stage) total=\(metrics.totalFrames) "
                    + "dropped=\(metrics.droppedFrames) corrupted=\(metrics.corruptedFrames) "
                    + "delay=\(String(format: "%.6f", metrics.accumulatedFrameDelay))"
            )
        }
        #endif
    }
}
