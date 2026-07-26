import ObjectiveC

extension MPVPictureInPictureCoordinator {
#if DEBUG
    private static var sampleBufferProbeAssociationKey: UInt8 = 0

    private var sampleBufferProbe: AnyObject? {
        get {
            objc_getAssociatedObject(self, &Self.sampleBufferProbeAssociationKey)
                as AnyObject?
        }
        set {
            objc_setAssociatedObject(
                self,
                &Self.sampleBufferProbeAssociationKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Starts only after AVKit reports active PiP. The initial screenshot used
    /// to bootstrap PiP is invalidated before the probe clears that queue, so
    /// test samples cannot be mixed with normal capture samples.
    func startSampleBufferProbeIfEnabled() -> Bool {
        guard #available(iOS 17.0, *),
              MPVPictureInPictureSampleBufferProbe.isEnabled,
              sampleBufferProbe == nil
        else { return false }
        guard let probe = MPVPictureInPictureSampleBufferProbe(
            displayLayer: sampleBufferDisplayLayer,
            log: { [weak playerView] message in playerView?.mpvDebugLog(message) },
            completion: { [weak self] in self?.resumeCaptureAfterSampleBufferProbe() }
        ) else {
            playerView?.mpvDebugLog(
                "[PiPProbe][ENQUEUE] stage=skipped reason=missing-control-timebase"
            )
            return false
        }

        // Cancelling the timer increments `frameCaptureGeneration`, causing a
        // screenshot callback already in flight to be ignored on return.
        stopFrameUpdates()
        sampleBufferProbe = probe
        probe.start()
        return true
    }

    func cancelSampleBufferProbe() {
        if #available(iOS 17.0, *) {
            (sampleBufferProbe as? MPVPictureInPictureSampleBufferProbe)?.cancel()
        }
    }

    private func resumeCaptureAfterSampleBufferProbe() {
        sampleBufferProbe = nil
        guard isActive, isTearingDown == false else { return }
        synchronizePlaybackTimebase()
        applyCaptureCadence(force: true)
        captureAndEnqueueFrame(force: true)
    }
#else
    func startSampleBufferProbeIfEnabled() -> Bool { false }

    func cancelSampleBufferProbe() {}
#endif
}
