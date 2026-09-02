import QuartzCore
import UIKit

/// Geometry written to CAMetalLayer only when a playback session starts.
/// It intentionally does not contain the view's current bounds.
struct MPVStableMetalCanvas: Equatable {
    let logicalSize: CGSize
    let drawableSize: CGSize
    let contentsScale: CGFloat
}

/// Pure mapping from the fixed renderer surface into the current controller
/// bounds. UIKit applies it to the live CAMetalLayer; libmpv never sees it.
struct MPVDisplayGeometry: Equatable {
    static let defaultVideoAspectRatio: CGFloat = 16.0 / 9.0

    let sourceVideoRect: CGRect
    let targetVideoRect: CGRect
    let scale: CGFloat
    let translation: CGPoint
    let rotation: CGFloat

    static func make(
        canvasSize: CGSize,
        videoAspectRatio: CGFloat,
        targetBounds: CGRect,
        contentMode: MPVContentModeSnapshot
    ) -> MPVDisplayGeometry {
        let safeCanvas = usableSize(canvasSize)
        let safeTarget = usableRect(targetBounds)
        let aspect = videoAspectRatio.isFinite && videoAspectRatio > 0.0
            ? videoAspectRatio
            : defaultVideoAspectRatio
        let sourceBounds = CGRect(origin: .zero, size: safeCanvas)
        let sourceVideoRect: CGRect
        let targetVideoRect: CGRect

        switch contentMode {
        case .fit:
            sourceVideoRect = aspectRect(aspect, in: sourceBounds, fill: false)
            targetVideoRect = aspectRect(aspect, in: safeTarget, fill: false)
        case .fill:
            // mpv's panscan fills and crops the fixed canvas. The pixels
            // available to UIKit are therefore the whole canvas; only the
            // target rect is allowed to extend beyond the controller bounds.
            sourceVideoRect = sourceBounds
            let canvasAspect = safeCanvas.width / max(safeCanvas.height, 1.0)
            targetVideoRect = aspectRect(canvasAspect, in: safeTarget, fill: true)
        }

        let scale = max(
            targetVideoRect.width / max(sourceVideoRect.width, 1.0),
            targetVideoRect.height / max(sourceVideoRect.height, 1.0)
        )
        let translation = CGPoint(
            x: targetVideoRect.midX - sourceVideoRect.midX * scale,
            y: targetVideoRect.midY - sourceVideoRect.midY * scale
        )
        return MPVDisplayGeometry(
            sourceVideoRect: sourceVideoRect,
            targetVideoRect: targetVideoRect,
            scale: scale,
            translation: translation,
            rotation: 0.0
        )
    }

    private static func usableSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite && size.width > 1.0 ? size.width : 1.0,
            height: size.height.isFinite && size.height > 1.0 ? size.height : 1.0
        )
    }

    private static func usableRect(_ rect: CGRect) -> CGRect {
        CGRect(origin: rect.origin, size: usableSize(rect.size))
    }

    private static func aspectRect(
        _ aspect: CGFloat,
        in bounds: CGRect,
        fill: Bool
    ) -> CGRect {
        let containerAspect = bounds.width / max(bounds.height, 1.0)
        let size: CGSize
        let fitsWidth = fill ? aspect < containerAspect : aspect > containerAspect
        if fitsWidth {
            size = CGSize(width: bounds.width, height: bounds.width / aspect)
        } else {
            size = CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGRect(
            x: bounds.midX - size.width / 2.0,
            y: bounds.midY - size.height / 2.0,
            width: size.width,
            height: size.height
        )
    }
}

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

    /// Called from the MPV queue before `wid` is assigned. A 90° controller
    /// rotation never changes this drawable or the Vulkan swapchain.
    nonisolated func prepareStableMetalCanvasForRendererSetup() {
        let apply = { @MainActor [self] in
            ensureStableMetalCanvas()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(apply)
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated(apply)
            }
        }
    }

    private func ensureStableMetalCanvas() {
        guard stableMetalCanvas == nil else { return }
        let screen = window?.windowScene?.screen ?? UIScreen.main
        let screenBounds = screen.bounds
        let logicalSize = CGSize(
            width: max(screenBounds.width, screenBounds.height),
            height: min(screenBounds.width, screenBounds.height)
        )
        let scale = max(screen.nativeScale, 1.0)
        let canvas = MPVStableMetalCanvas(
            logicalSize: logicalSize,
            drawableSize: CGSize(
                width: logicalSize.width * scale,
                height: logicalSize.height * scale
            ),
            contentsScale: scale
        )
        stableMetalCanvas = canvas

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        metalLayer.bounds = CGRect(origin: .zero, size: canvas.logicalSize)
        metalLayer.contentsScale = canvas.contentsScale
        metalLayer.drawableSize = canvas.drawableSize
        metalLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        metalLayer.transform = CATransform3DIdentity
        CATransaction.commit()

        mpvDebugLog(
            "stable metal canvas prepared logical=\(canvas.logicalSize) "
                + "drawable=\(canvas.drawableSize) scale=\(canvas.contentsScale)"
        )
    }

    func updateMetalLayerGeometryIfNeeded(
        animated _: Bool = true,
        reconfigureVideoOutput _: Bool = true
    ) {
        if Thread.isMainThread == false {
            DispatchQueue.main.async { [weak self] in
                self?.updateMetalLayerGeometryIfNeeded()
            }
            return
        }
        updateDisplayPresentationMapping(reason: "layout")
    }

    @objc public func beginDisplayGeometryTransition() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.beginDisplayGeometryTransition()
            }
            return
        }
        mpvDebugLog(
            "display geometry transition began bounds=\(bounds) "
                + "canvas=\(stableMetalCanvas?.logicalSize ?? .zero)"
        )
    }

    @objc public func endDisplayGeometryTransition() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.endDisplayGeometryTransition()
            }
            return
        }
        updateDisplayPresentationMapping(reason: "display-transition-end")
        mpvDebugLog(
            "display geometry transition ended bounds=\(bounds) "
                + "current=\(currentTime) duration=\(duration) playing=\(isPlaying)"
        )
    }

    /// PiP changes the presentation container, not the renderer surface.
    func resynchronizeMetalLayerGeometry(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.resynchronizeMetalLayerGeometry(reason: reason)
            }
            return
        }
        layoutIfNeeded()
        guard bounds.width > 0.0, bounds.height > 0.0 else {
            pendingPictureInPictureGeometryResynchronizationReason = reason
            mpvDebugLog("display mapping resync deferred reason=\(reason) bounds=\(bounds)")
            schedulePictureInPictureGeometryResynchronization(reason: reason)
            return
        }
        pendingPictureInPictureGeometryResynchronizationReason = nil
        updateDisplayPresentationMapping(reason: reason)
    }

    func updateMetalLayerGeometry(
        for targetBounds: CGRect,
        scale _: CGFloat,
        transitionReason: String,
        animated _: Bool,
        reconfigureVideoOutput _: Bool = true
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateMetalLayerGeometry(
                    for: targetBounds,
                    scale: 1.0,
                    transitionReason: transitionReason,
                    animated: false
                )
            }
            return
        }
        updateDisplayPresentationMapping(
            targetSize: targetBounds.size,
            reason: transitionReason
        )
    }

    func updateDisplayPresentationMapping(reason: String) {
        updateDisplayPresentationMapping(targetSize: bounds.size, reason: reason)
    }

    func updateDisplayPresentationMapping(targetSize: CGSize, reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateDisplayPresentationMapping(targetSize: targetSize, reason: reason)
            }
            return
        }
        guard targetSize.width > 1.0, targetSize.height > 1.0 else { return }
        ensureStableMetalCanvas()
        guard let canvas = stableMetalCanvas else { return }

        let aspect = currentVideoDisplayAspectRatio()
        let mapping = MPVDisplayGeometry.make(
            canvasSize: canvas.logicalSize,
            videoAspectRatio: aspect,
            targetBounds: CGRect(origin: .zero, size: targetSize),
            contentMode: currentContentModeSnapshot()
        )
        let canvasCenter = CGPoint(
            x: canvas.logicalSize.width / 2.0,
            y: canvas.logicalSize.height / 2.0
        )
        let layerPosition = CGPoint(
            x: canvasCenter.x * mapping.scale + mapping.translation.x,
            y: canvasCenter.y * mapping.scale + mapping.translation.y
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        metalLayer.position = layerPosition
        metalLayer.transform = CATransform3DMakeScale(mapping.scale, mapping.scale, 1.0)
        CATransaction.commit()

        mpvDebugLog(
            "display mapping applied reason=\(reason) target=\(targetSize) "
                + "aspect=\(aspect) source=\(mapping.sourceVideoRect) "
                + "targetVideo=\(mapping.targetVideoRect) scale=\(mapping.scale) "
                + "translation=\(mapping.translation) rotation=0"
        )
    }

    func currentVideoDisplayAspectRatio() -> CGFloat {
        videoDisplayAspectRatioLock.lock()
        defer { videoDisplayAspectRatioLock.unlock() }
        return videoDisplayAspectRatio
    }

    nonisolated func updateVideoDisplayAspectRatio(width: Int64?, height: Int64?) {
        guard let width, let height, width > 0, height > 0 else { return }
        let aspect = CGFloat(width) / CGFloat(height)
        guard aspect.isFinite, aspect > 0.0 else { return }
        videoDisplayAspectRatioLock.lock()
        let changed = abs(videoDisplayAspectRatio - aspect) > 0.0001
        videoDisplayAspectRatio = aspect
        videoDisplayAspectRatioLock.unlock()
        guard changed else { return }
        notifyOnMain {
            self.updateDisplayPresentationMapping(reason: "video-aspect")
        }
    }

    func schedulePictureInPictureGeometryResynchronization(reason: String) {
        pictureInPictureGeometryResynchronizationTask?.cancel()
        pictureInPictureGeometryResynchronizationGeneration &+= 1
        let generation = pictureInPictureGeometryResynchronizationGeneration
        pictureInPictureGeometryResynchronizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastBounds: CGRect?
            for attempt in 0..<8 {
                guard Task.isCancelled == false,
                      generation == self.pictureInPictureGeometryResynchronizationGeneration else {
                    return
                }
                self.setNeedsLayout()
                self.superview?.setNeedsLayout()
                self.window?.setNeedsLayout()
                self.window?.layoutIfNeeded()
                self.superview?.layoutIfNeeded()
                self.layoutIfNeeded()
                let currentBounds = self.bounds
                guard currentBounds.width > 0.0, currentBounds.height > 0.0 else {
                    self.pendingPictureInPictureGeometryResynchronizationReason = reason
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                if attempt == 0 || currentBounds != lastBounds {
                    self.pendingPictureInPictureGeometryResynchronizationReason = nil
                    self.updateDisplayPresentationMapping(reason: reason)
                    lastBounds = currentBounds
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if generation == self.pictureInPictureGeometryResynchronizationGeneration {
                self.pictureInPictureGeometryResynchronizationTask = nil
            }
        }
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
