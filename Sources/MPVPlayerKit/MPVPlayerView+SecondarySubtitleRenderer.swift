import UIKit

extension MPVPlayerView {
    func installSecondarySubtitleRenderer() {
        let overlay = secondarySubtitleRenderer.view
        overlay.accessibilityIdentifier = "MPVPlayer.secondarySubtitleRenderer"
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 文本仍由 mpv 解码和按各路 delay 定时，UIKit 仅负责绘制。
    nonisolated func refreshSecondarySubtitleText(state: MPVSubtitleState) {
        let usesOverlay = shouldRenderDecodedSubtitleText(id: state.trackID, usesOriginalStyle: state.usesOriginalStyle)
        let text = usesOverlay && state.visible ? getString(MPVSubtitleSlot.secondary.textProperty) ?? "" : nil
        let session = currentBufferingSessionGeneration()
        let revision = subtitleSlots.nextTextRevision(.secondary)
        notifyOnMain {
            guard self.currentBufferingSessionGeneration() == session, !self.isStopped(),
                  self.subtitleSlots.isCurrentTextRevision(revision, slot: .secondary) else { return }
            self.secondaryDecodedSubtitleText = text
            self.secondarySubtitleRenderer.verticalPosition = state.position
            self.renderSecondarySubtitleText()
        }
    }

    func renderSecondarySubtitleText() {
        let state = subtitleSlots.snapshot(.secondary)
        let text = state.visible && !state.isNative && state.trackID != nil ? secondaryDecodedSubtitleText ?? "" : ""
        secondarySubtitleRenderer.render(MPVSubtitlePresentation(
            cues: text.isEmpty ? [] : [MPVSubtitleCue(startTime: 0, endTime: .greatestFiniteMagnitude, text: text)],
            style: clientSubtitleController.style
        ))
    }
}
