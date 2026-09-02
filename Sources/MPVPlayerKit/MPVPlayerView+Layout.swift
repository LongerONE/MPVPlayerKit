import AVFoundation
import QuartzCore
import UIKit
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

struct MPVMetalLayerGeometry: Equatable {
    let layerBounds: CGRect
    let drawableSize: CGSize
    let contentsScale: CGFloat
}

extension MPVPlayerView {
    func setContentModeSnapshot(_ contentModeSnapshot: MPVContentModeSnapshot) {
        contentModeSnapshotLock.lock()
        self.contentModeSnapshot = contentModeSnapshot
        contentModeSnapshotLock.unlock()
    }

    func currentContentModeSnapshot() -> MPVContentModeSnapshot {
        contentModeSnapshotLock.lock()
        defer { contentModeSnapshotLock.unlock() }
        return contentModeSnapshot
    }

    func applyContentMode(_ contentModeSnapshot: MPVContentModeSnapshot) {
        switch contentModeSnapshot {
        case .fill:
            setDouble(MPVProperty.panscan, 1.0)
        case .fit:
            setDouble(MPVProperty.panscan, 0.0)
        }
    }

    func applyContentMode(_ contentMode: UIView.ContentMode) {
        applyContentMode(MPVContentModeSnapshot(contentModeRawValue: contentMode.rawValue))
    }

    func layoutTargetSize(from options: NSDictionary) -> CGSize {
        let width = (options["width"] as? NSNumber)?.doubleValue ?? Double(bounds.width)
        let height = (options["height"] as? NSNumber)?.doubleValue ?? Double(bounds.height)
        return CGSize(width: width, height: height)
    }

    func updateMetalLayerGeometryIfNeeded(
        animated: Bool = true,
        reconfigureVideoOutput: Bool = true
    ) {
        if Thread.isMainThread == false {
            DispatchQueue.main.async { [weak self] in
                self?.updateMetalLayerGeometryIfNeeded(
                    animated: animated,
                    reconfigureVideoOutput: reconfigureVideoOutput
                )
            }
            return
        }

        updateMetalLayerGeometry(
            for: CGRect(origin: .zero, size: bounds.size),
            scale: UIScreen.main.nativeScale,
            transitionReason: "layout",
            animated: animated,
            reconfigureVideoOutput: reconfigureVideoOutput
        )
    }

    @objc public func beginDisplayGeometryTransition() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.beginDisplayGeometryTransition()
            }
            return
        }
        isDisplayGeometryTransitionDeferred = true
        mpvDebugLog("display geometry transition began")
    }

    @objc public func endDisplayGeometryTransition() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.endDisplayGeometryTransition()
            }
            return
        }
        isDisplayGeometryTransitionDeferred = false
        mpvDebugLog(
            "display geometry transition ended bounds=\(bounds) "
                + "current=\(currentTime) duration=\(duration) playing=\(isPlaying)"
        )
        // UIKit has completed the display rotation. Update only the
        // presentation layer here; toggling `vid` would tear down and rebuild
        // the active video output and report a false cache wait to clients.
        updateMetalLayerGeometryIfNeeded(
            animated: false,
            reconfigureVideoOutput: false
        )
    }

    /// Re-sizes the renderer to the view after it changed window hierarchy.
    ///
    /// Picture in Picture moves this view between the inline hierarchy and the
    /// Picture in Picture window. A plain layout pass is not enough to recover
    /// from that: the layer keeps presenting the drawable it last produced at
    /// the other size, and MPV is only told about a new size when the geometry
    /// is applied, so a size that happens to match the one applied last would
    /// be skipped and leave the window rendering at the previous size. The
    /// change test is therefore cleared rather than consulted.
    func resynchronizeMetalLayerGeometry(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.resynchronizeMetalLayerGeometry(reason: reason)
            }
            return
        }
        layoutIfNeeded()
        guard bounds.width > 0, bounds.height > 0 else {
            pendingPictureInPictureGeometryResynchronizationReason = reason
            mpvDebugLog("metal geometry resync deferred reason=\(reason) bounds=\(bounds)")
            schedulePictureInPictureGeometryResynchronization(reason: reason)
            return
        }
        pendingPictureInPictureGeometryResynchronizationReason = nil
        mpvDebugLog("metal geometry resync reason=\(reason) bounds=\(bounds)")
        lastAppliedLayerBounds = .null
        lastAppliedDrawableSize = .zero
        updateMetalLayerGeometry(
            for: CGRect(origin: .zero, size: bounds.size),
            scale: UIScreen.main.nativeScale,
            transitionReason: reason,
            // The system animates the Picture in Picture transition itself, so
            // the snapshot cross fade would only show a stale frame over it.
            animated: false
        )
    }

    /// PiP delegate callbacks can arrive while AVKit is still restoring the
    /// inline hierarchy. Rotation fixes the symptom because it performs a new
    /// layout pass; do the equivalent here for a short, bounded period instead
    /// of leaving the PiP-sized drawable visible until the user rotates.
    func schedulePictureInPictureGeometryResynchronization(reason: String) {
        pictureInPictureGeometryResynchronizationTask?.cancel()
        pictureInPictureGeometryResynchronizationGeneration &+= 1
        let generation = pictureInPictureGeometryResynchronizationGeneration

        pictureInPictureGeometryResynchronizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastResynchronizedBounds: CGRect?

            // AVKit completes the return animation asynchronously. Eight
            // passes cover that transition without a persistent polling loop.
            for attempt in 0..<8 {
                guard Task.isCancelled == false,
                      generation == self.pictureInPictureGeometryResynchronizationGeneration
                else {
                    return
                }

                // Avoid a nested resynchronization from layoutSubviews; this
                // task owns the forced update for this pass.
                self.pendingPictureInPictureGeometryResynchronizationReason = nil
                self.layoutPictureInPictureHierarchy()

                let currentBounds = self.bounds
                guard currentBounds.width > 0, currentBounds.height > 0 else {
                    self.pendingPictureInPictureGeometryResynchronizationReason = reason
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                if attempt == 0 || currentBounds != lastResynchronizedBounds {
                    self.resynchronizeMetalLayerGeometry(reason: reason)
                    lastResynchronizedBounds = currentBounds
                }

                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            guard generation == self.pictureInPictureGeometryResynchronizationGeneration else {
                return
            }
            self.pictureInPictureGeometryResynchronizationTask = nil
        }
    }

    private func layoutPictureInPictureHierarchy() {
        setNeedsLayout()
        var ancestor = superview
        while let currentAncestor = ancestor {
            currentAncestor.setNeedsLayout()
            ancestor = currentAncestor.superview
        }
        window?.setNeedsLayout()
        window?.layoutIfNeeded()
        superview?.layoutIfNeeded()
        layoutIfNeeded()
    }

    func updateMetalLayerGeometry(
        for targetBounds: CGRect,
        scale: CGFloat,
        transitionReason: String,
        animated: Bool,
        reconfigureVideoOutput: Bool = true
    ) {
        let geometry = MPVMetalLayerGeometry(
            layerBounds: CGRect(origin: .zero, size: targetBounds.size),
            drawableSize: CGSize(
                width: targetBounds.size.width * scale,
                height: targetBounds.size.height * scale
            ),
            contentsScale: scale
        )
        let geometryChanged = hasMetalGeometryChanged(
            layerBounds: geometry.layerBounds,
            drawableSize: geometry.drawableSize
        )

        guard geometryChanged else { return }

        guard mpv != nil else {
            applyMetalLayerGeometry(geometry)
            return
        }

        if reconfigureVideoOutput == false {
            pendingMetalLayerGeometry = nil
            resetGeometryTransitionAnimation(reason: "display-transition")
            applyMetalLayerGeometry(geometry)
            refreshVideoGeometryWithoutOutputReconfiguration()
            mpvDebugLog(
                "metal geometry applied without video output reconfiguration "
                    + "bounds=\(geometry.layerBounds) drawable=\(geometry.drawableSize) "
                    + "current=\(currentTime) duration=\(duration) playing=\(isPlaying)"
            )
            return
        }

        if isDisplayGeometryTransitionDeferred {
            mpvDebugLog(
                "metal geometry deferred during display transition geometry=\(geometry) "
                    + "current=\(currentTime) duration=\(duration) playing=\(isPlaying)"
            )
            return
        }

        pendingMetalLayerGeometry = geometry
        guard isMetalGeometryTransitionInProgress == false else { return }
        if animated {
            animateGeometryTransitionOut(
                targetSize: geometry.layerBounds.size,
                reason: transitionReason
            )
        } else {
            resetGeometryTransitionAnimation(reason: transitionReason)
        }
        beginMetalGeometryTransition()
    }

    /// Refreshes MPV's destination rectangle after UIKit changes the
    /// CAMetalLayer size. Changing the layer alone updates MoltenVK's
    /// swapchain, but `vo_gpu_next` can retain the previous destination
    /// rectangle. A tiny panscan pulse reaches MPV's resize-only path without
    /// toggling `vid`, so the active decoder and network cache stay intact.
    private func refreshVideoGeometryWithoutOutputReconfiguration() {
        guard mpv != nil else { return }

        let currentContentMode = currentContentModeSnapshot()
        let finalPanscan: Double = currentContentMode == .fill ? 1.0 : 0.0
        let temporaryPanscan = currentContentMode == .fill ? 0.999 : 0.001
        let targetDrawableSize = metalLayer.drawableSize

        queue.async { [weak self] in
            guard let self, self.mpv != nil, self.isStopped() == false else { return }

            let status = self.setDouble(MPVProperty.panscan, temporaryPanscan)
            self.mpvDebugLog(
                "video geometry resize-only refresh requested "
                    + "panscan=\(temporaryPanscan) target=\(targetDrawableSize) status=\(status)"
            )

            // Keep the pulse long enough for MPV to process the first option
            // update. Read the mode again so a user change during rotation is
            // not overwritten by the delayed restore.
            self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.mpv != nil, self.isStopped() == false else { return }
                let latestContentMode = self.currentContentModeSnapshot()
                let restoredPanscan = latestContentMode == .fill ? finalPanscan : 0.0
                let restoreStatus = self.setDouble(MPVProperty.panscan, restoredPanscan)
                self.mpvDebugLog(
                    "video geometry resize-only refresh restored "
                        + "panscan=\(restoredPanscan) target=\(targetDrawableSize) "
                        + "status=\(restoreStatus)"
                )
            }
        }
    }

    private func applyMetalLayerGeometry(_ geometry: MPVMetalLayerGeometry) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = geometry.layerBounds
        metalLayer.contentsScale = geometry.contentsScale
        metalLayer.drawableSize = geometry.drawableSize
        CATransaction.commit()

        lastAppliedLayerBounds = geometry.layerBounds
        lastAppliedDrawableSize = geometry.drawableSize
        mpvDebugLog(
            "metal geometry applied bounds=\(geometry.layerBounds) "
                + "drawable=\(geometry.drawableSize) scale=\(geometry.contentsScale)"
        )
    }

    private func beginMetalGeometryTransition() {
        isMetalGeometryTransitionInProgress = true
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv, self.isStopped() == false else {
                DispatchQueue.main.async { [weak self] in
                    self?.applyPendingMetalGeometryWithoutVideoOutput()
                }
                return
            }
            self.mpvDebugLog(
                "metal geometry transition suspending video output "
                    + "current=\(self.currentTime) duration=\(self.duration) playing=\(self.isPlaying)"
            )
            let suspendResult = mpv_set_property_string(mpv, MPVProperty.videoID, "no")
            self.checkError(
                suspendResult,
                operation: "layout transition vid=no",
                notifyOnFailure: false
            )
            guard suspendResult >= 0 else {
                DispatchQueue.main.async { [weak self] in
                    self?.cancelMetalGeometryTransitionAfterSuspendFailure()
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyPendingMetalGeometryAndResumeVideoOutput()
            }
        }
    }

    private func applyPendingMetalGeometryWithoutVideoOutput() {
        if let geometry = pendingMetalLayerGeometry {
            pendingMetalLayerGeometry = nil
            applyMetalLayerGeometry(geometry)
        }
        isMetalGeometryTransitionInProgress = false
        animateGeometryTransitionIn()
    }

    private func cancelMetalGeometryTransitionAfterSuspendFailure() {
        pendingMetalLayerGeometry = nil
        isMetalGeometryTransitionInProgress = false
        animateGeometryTransitionIn()
    }

    private func applyPendingMetalGeometryAndResumeVideoOutput() {
        guard let geometry = pendingMetalLayerGeometry else {
            isMetalGeometryTransitionInProgress = false
            animateGeometryTransitionIn()
            return
        }
        pendingMetalLayerGeometry = nil
        applyMetalLayerGeometry(geometry)

        let contentModeSnapshot = currentContentModeSnapshot()
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv, self.isStopped() == false else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishMetalGeometryTransition()
                }
                return
            }
            self.checkError(
                mpv_set_property_string(mpv, MPVProperty.videoID, "auto"),
                operation: "layout transition vid=auto",
                notifyOnFailure: false
            )
            self.applyContentMode(contentModeSnapshot)
            self.mpvDebugLog(
                "metal geometry transition resumed video output "
                    + "bounds=\(geometry.layerBounds) drawable=\(geometry.drawableSize)"
            )
            DispatchQueue.main.async { [weak self] in
                self?.finishMetalGeometryTransition()
            }
        }
    }

    private func finishMetalGeometryTransition() {
        isMetalGeometryTransitionInProgress = false
        if isDisplayGeometryTransitionDeferred {
            resetGeometryTransitionAnimation(reason: "display-transition")
            return
        }
        if pendingMetalLayerGeometry != nil {
            beginMetalGeometryTransition()
        } else {
            animateGeometryTransitionIn()
        }
    }

    func hasMetalGeometryChanged(layerBounds: CGRect, drawableSize: CGSize) -> Bool {
        guard layerBounds.width > 1.0, layerBounds.height > 1.0 else {
            return false
        }
        if lastAppliedLayerBounds.isNull {
            return true
        }
        return abs(lastAppliedLayerBounds.width - layerBounds.width) > 0.5
            || abs(lastAppliedLayerBounds.height - layerBounds.height) > 0.5
            || abs(lastAppliedDrawableSize.width - drawableSize.width) > 0.5
            || abs(lastAppliedDrawableSize.height - drawableSize.height) > 0.5
    }

    func animateGeometryTransitionOut(targetSize: CGSize, reason: String) {
        prepareGeometryTransitionOverlay(targetSize: targetSize, reason: reason)
    }

    func prepareGeometryTransitionOverlay(targetSize: CGSize, reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.prepareGeometryTransitionOverlay(targetSize: targetSize, reason: reason)
            }
            return
        }
        guard mpv != nil else {
            return
        }
        guard UIAccessibility.isReduceMotionEnabled == false else {
            resetGeometryTransitionAnimation(reason: "reduce-motion")
            return
        }
        guard targetSize.width > 1.0, targetSize.height > 1.0, bounds.width > 1.0, bounds.height > 1.0 else {
            return
        }
        if geometryTransitionOverlayView != nil,
           isLayoutSizeClose(geometryTransitionPreparedTargetSize, targetSize) {
            return
        }
        guard isLayoutSizeClose(targetSize, bounds.size) == false else {
            mpvDebugLog("geometry transition skipped reason=\(reason) sameSize bounds=\(bounds) target=\(targetSize)")
            resetGeometryTransitionAnimation(reason: "same-size-\(reason)")
            return
        }

        geometryTransitionAnimationID += 1
        geometryTransitionPreparedTargetSize = targetSize
        geometryTransitionOverlayView?.removeFromSuperview()

        guard let snapshotView = snapshotView(afterScreenUpdates: false)
            ?? resizableSnapshotView(from: bounds, afterScreenUpdates: false, withCapInsets: .zero) else {
            mpvDebugLog("geometry transition skipped reason=\(reason) noSnapshot bounds=\(bounds) target=\(targetSize)")
            resetGeometryTransitionAnimation(reason: "no-snapshot-\(reason)")
            return
        }

        let overlayView = UIView(frame: bounds)
        overlayView.isUserInteractionEnabled = false
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.backgroundColor = UIColor.black.withAlphaComponent(geometryTransitionFallbackAlpha)

        snapshotView.frame = overlayView.bounds
        snapshotView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.addSubview(snapshotView)

        let dimView = UIView(frame: overlayView.bounds)
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.backgroundColor = .black
        dimView.alpha = geometryTransitionDimAlpha
        overlayView.addSubview(dimView)

        addSubview(overlayView)
        bringSubviewToFront(overlayView)
        geometryTransitionOverlayView = overlayView
        let transitionID = geometryTransitionAnimationID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak overlayView] in
            guard let self,
                  self.geometryTransitionAnimationID == transitionID,
                  self.geometryTransitionOverlayView === overlayView else {
                return
            }
            self.mpvDebugLog("geometry transition overlay timeout fade out id=\(transitionID) reason=\(reason) bounds=\(self.bounds) target=\(targetSize)")
            self.animateGeometryTransitionIn()
        }
        mpvDebugLog("geometry transition overlay prepared id=\(geometryTransitionAnimationID) reason=\(reason) bounds=\(bounds) target=\(targetSize) hasSnapshot=true fallbackAlpha=\(geometryTransitionFallbackAlpha) dimAlpha=\(geometryTransitionDimAlpha)")
    }

    func animateGeometryTransitionIn() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.animateGeometryTransitionIn()
            }
            return
        }
        guard UIAccessibility.isReduceMotionEnabled == false else {
            resetGeometryTransitionAnimation(reason: "reduce-motion")
            return
        }
        geometryTransitionAnimationID += 1
        geometryTransitionPreparedTargetSize = .zero
        let transitionID = geometryTransitionAnimationID
        guard let overlayView = geometryTransitionOverlayView else {
            return
        }
        mpvDebugLog("geometry transition overlay fade out id=\(transitionID) bounds=\(bounds)")
        UIView.animate(
            withDuration: geometryTransitionFadeOutDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            overlayView.alpha = 0.0
        } completion: { [weak self, weak overlayView] _ in
            guard let self else { return }
            if self.geometryTransitionAnimationID == transitionID {
                self.geometryTransitionOverlayView = nil
            }
            overlayView?.removeFromSuperview()
        }
    }

    func resetGeometryTransitionAnimation(reason: String = "reset") {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.resetGeometryTransitionAnimation(reason: reason)
            }
            return
        }
        let hadOverlay = geometryTransitionOverlayView != nil
        geometryTransitionAnimationID += 1
        geometryTransitionPreparedTargetSize = .zero
        geometryTransitionOverlayView?.layer.removeAllAnimations()
        geometryTransitionOverlayView?.removeFromSuperview()
        geometryTransitionOverlayView = nil
        mpvDebugLog("geometry transition reset reason=\(reason) hadOverlay=\(hadOverlay) id=\(geometryTransitionAnimationID)")
    }

    func isLayoutSizeClose(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
    }

    func startTimeTimer() {
        guard timeTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(500),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler(handler: makeMPVTimeTimerHandler(self))
        timeTimer = timer
        timer.resume()
    }

    func stopTimeTimer() {
        timeTimer?.setEventHandler {}
        timeTimer?.cancel()
        timeTimer = nil
    }

}
