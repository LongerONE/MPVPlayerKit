import UIKit

extension MPVPlayerView {
    public var subtitleLayoutMode: MPVSubtitleLayoutMode {
        get { subtitleLayoutModeValue }
        set { subtitleLayoutModeValue = newValue; updateSubtitleLayoutPlacement() }
    }

    @objc public func updateSubtitleLayout(_ options: NSDictionary) {
        subtitleLayoutMode = MPVSubtitleLayoutMode(rawValue: (options["mode"] as? NSNumber)?.intValue ?? 0) ?? .independent
    }

    @objc public func subtitleLayoutState() -> NSDictionary {
        let status = subtitleLayoutStatus
        return ["requestedMode": status.requestedMode.rawValue, "effectiveMode": status.effectiveMode.rawValue,
                "fallbackReason": status.fallbackReason?.rawValue ?? ""] as NSDictionary
    }

    public var subtitleLayoutStatus: MPVSubtitleLayoutStatus {
        guard subtitleLayoutMode == .stacked else { return .init(requestedMode: .independent) }
        for slot in MPVSubtitleSlot.allCases where isSubtitleLayoutSlotActive(slot) {
            let state = subtitleSlots.snapshot(slot)
            if slot == .primary && clientSubtitleController.hasSelection {
                if !(clientSubtitleController.renderer is MPVDefaultSubtitleRenderer) {
                    return .init(requestedMode: .stacked, fallbackReason: .unsupportedRenderer)
                }
                continue
            }
            if state.shadowRadiusCapability == .imageSubtitle { return .init(requestedMode: .stacked, fallbackReason: .imageSubtitle) }
            if state.usesOriginalStyle { return .init(requestedMode: .stacked, fallbackReason: .originalStyle) }
            if state.isNative || (slot == .primary && !(clientSubtitleController.renderer is MPVDefaultSubtitleRenderer)) {
                return .init(requestedMode: .stacked, fallbackReason: .unsupportedRenderer)
            }
        }
        let heights = subtitleGroupHeights()
        if bounds.height > 0 && heights.0 + heights.1 + heights.2 > bounds.height {
            return .init(requestedMode: .stacked, fallbackReason: .insufficientSpace)
        }
        return .init(requestedMode: .stacked)
    }

    func installSubtitleLayoutCallbacks() {
        (clientSubtitleController.renderer as? MPVDefaultSubtitleRenderer)?.onPresentationChanged = { [weak self] in
            self?.updateSubtitleLayoutPlacement()
        }
        secondarySubtitleRenderer.onPresentationChanged = { [weak self] in self?.updateSubtitleLayoutPlacement() }
        updateSubtitleLayoutPlacement()
    }

    func updateSubtitleLayoutPlacement() {
        let primary = clientSubtitleController.renderer as? MPVDefaultSubtitleRenderer
        guard subtitleLayoutStatus.effectiveMode == .stacked, bounds.height > 0 else {
            primary?.applyGroupBottomOffset(nil)
            secondarySubtitleRenderer.applyGroupBottomOffset(nil)
            return
        }
        let (firstHeight, secondHeight, gap) = subtitleGroupHeights()
        let total = firstHeight + secondHeight + gap
        let videoRect = subtitleLayoutVideoRect()
        let margin = CGFloat(clientSubtitleController.style.bottomOffset) * max(videoRect.height, 180) / 720
        let travel = max(0, videoRect.height - margin * 2 - total)
        let position = subtitleSlots.snapshot(.primary).position
        let desiredBottom = videoRect.maxY - margin - travel * CGFloat((100 - position) / 100)
        let bottom = min(bounds.maxY, max(bounds.minY + total, desiredBottom))
        let offset = bounds.maxY - bottom
        primary?.applyGroupBottomOffset(offset + secondHeight + gap)
        secondarySubtitleRenderer.applyGroupBottomOffset(offset)
    }

    private func isSubtitleLayoutSlotActive(_ slot: MPVSubtitleSlot) -> Bool {
        if slot == .primary && clientSubtitleController.hasSelection { return clientSubtitleController.isVisible }
        let state = subtitleSlots.snapshot(slot)
        return state.visible && state.trackID != nil
    }

    private func subtitleGroupHeights() -> (CGFloat, CGFloat, CGFloat) {
        let width = max(1, bounds.width - 40)
        let first = isSubtitleLayoutSlotActive(.primary)
            ? (clientSubtitleController.renderer as? MPVDefaultSubtitleRenderer)?.textHeight(for: width) ?? 0 : 0
        let second = isSubtitleLayoutSlotActive(.secondary) ? secondarySubtitleRenderer.textHeight(for: width) : 0
        let gap = first > 0 && second > 0 ? max(1, subtitleLayoutVideoRect().height / 360) : 0
        return (first, second, gap)
    }

    private func subtitleLayoutVideoRect() -> CGRect {
        let mode: MPVContentModeSnapshot = videoDisplayMode == .fill ? .fill : .fit
        return MPVDisplayGeometry.make(canvasSize: bounds.size, videoAspectRatio: currentVideoDisplayAspectRatio(),
            targetBounds: bounds, contentMode: mode).targetVideoRect.intersection(bounds)
    }
}

extension MPVPlayer {
    public var subtitleLayoutMode: MPVSubtitleLayoutMode {
        get { playbackView.subtitleLayoutMode }
        set { playbackView.subtitleLayoutMode = newValue }
    }
    public var subtitleLayoutStatus: MPVSubtitleLayoutStatus { playbackView.subtitleLayoutStatus }
}
