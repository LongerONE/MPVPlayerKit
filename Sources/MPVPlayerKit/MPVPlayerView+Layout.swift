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

    func updateMetalLayerGeometryIfNeeded() {
        if Thread.isMainThread == false {
            DispatchQueue.main.async { [weak self] in
                self?.updateMetalLayerGeometryIfNeeded()
            }
            return
        }

        let scale = UIScreen.main.nativeScale
        let layerBounds = CGRect(origin: .zero, size: bounds.size)
        let drawableSize = CGSize(
            width: bounds.size.width * scale,
            height: bounds.size.height * scale
        )
        let geometryChanged = hasMetalGeometryChanged(
            layerBounds: layerBounds,
            drawableSize: drawableSize
        )

        if mpv != nil, geometryChanged {
            animateGeometryTransitionOut(targetSize: layerBounds.size, reason: "layout")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = layerBounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = drawableSize
        CATransaction.commit()

        lastAppliedLayerBounds = layerBounds
        lastAppliedDrawableSize = drawableSize

        if mpv != nil, geometryChanged {
            mpvDebugLog("metal geometry changed bounds=\(layerBounds) drawable=\(drawableSize) scale=\(scale)")
            applyContentMode(contentMode)
            scheduleVideoOutputRefresh(drawableSize: drawableSize, layerBounds: layerBounds, contentMode: contentMode)
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

    func scheduleVideoOutputRefresh(drawableSize: CGSize, layerBounds: CGRect, contentMode: UIView.ContentMode) {
        videoOutputRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshVideoOutputAfterGeometryChange(
                drawableSize: drawableSize,
                layerBounds: layerBounds,
                contentMode: contentMode
            )
        }
        videoOutputRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func refreshVideoOutputAfterGeometryChange(drawableSize: CGSize, layerBounds: CGRect, contentMode: UIView.ContentMode) {
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv, self.stopped == false else { return }
            self.mpvDebugLog("video output refresh begin bounds=\(layerBounds) drawable=\(drawableSize)")
            self.checkError(
                mpv_set_option_string(mpv, "vid", "no"),
                operation: "layout refresh vid=no",
                notifyOnFailure: false
            )
            self.checkError(
                mpv_set_option_string(mpv, "vid", "auto"),
                operation: "layout refresh vid=auto",
                notifyOnFailure: false
            )
            self.applyContentMode(contentMode)
            self.mpvDebugLog("video output refresh end bounds=\(layerBounds) drawable=\(drawableSize)")
            DispatchQueue.main.async { [weak self] in
                self?.animateGeometryTransitionIn()
            }
        }
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
