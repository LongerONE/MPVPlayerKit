import MediaPlayer
import UIKit
import UniformTypeIdentifiers

extension MPVQuickPlayerViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer {
            return true
        }
        guard gestureOptions.isEmpty == false else { return false }
        let location = gestureRecognizer.location(in: view)
        let controlsFrame = controlsView.convert(controlsView.bounds, to: view)
        guard controlsFrame.contains(location) == false else { return false }
        guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = panGesture.velocity(in: contentView)
        return abs(velocity.x) > 1 || abs(velocity.y) > 1
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        var touchedView = touch.view
        while let view = touchedView {
            if view is UIControl { return false }
            touchedView = view.superview
        }
        return true
    }
}

extension MPVQuickPlayerViewController: MPVPlayerDelegate {
    public func player(_ player: MPVPlayer, didChangeState state: MPVPlaybackState) {
        playbackState = state
        let isPlaying = state == .buffering || state == .readyToPlay || state == .bufferFinished
        playButton.setImage(UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        if Self.shouldShowLoading(for: state) {
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
        updateStatusLabel()
        if state == .error {
            presentMessage(
                title: mpvLocalized("playback.error.title"),
                message: mpvLocalized("playback.error.message")
            )
        }
    }

    public func player(
        _ player: MPVPlayer,
        didUpdateCurrentTime currentTime: TimeInterval,
        duration: TimeInterval
    ) {
        progressSlider.maximumValue = Float(max(duration, 1))
        if isScrubbing == false {
            progressSlider.value = Float(min(max(currentTime, 0), max(duration, 1)))
            timeLabel.text = Self.timeDescription(currentTime: currentTime, duration: duration)
        }
    }

    public func player(_ player: MPVPlayer, didUpdateBufferingProgress progress: Int) {
        bufferingProgress = min(max(progress, 0), 100)
        updateStatusLabel()
    }

    public func player(_ player: MPVPlayer, didUpdateDecoderMode mode: MPVDecoderMode) {
        decoderMode = mode
        updateStatusLabel()
    }
}

extension MPVQuickPlayerViewController: UIDocumentPickerDelegate {
    public func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else { return }
        let subtitleExtension = url.pathExtension.lowercased()
        guard subtitleExtension == "ass" || subtitleExtension == "ssa" else {
            presentAfterCurrentSheet { controller in
                controller.loadExternalSubtitle(from: url, usesOriginalStyle: false)
            }
            return
        }

        presentAfterCurrentSheet { controller in
            let alert = controller.actionSheet(
                title: mpvLocalized("subtitle.style"),
                sourceView: controller.subtitleButton
            )
            alert.addAction(UIAlertAction(title: mpvLocalized("subtitle.style.use_file"), style: .default) { [weak controller] _ in
                controller?.loadExternalSubtitle(from: url, usesOriginalStyle: true)
            })
            alert.addAction(UIAlertAction(title: mpvLocalized("subtitle.style.use_player"), style: .default) { [weak controller] _ in
                controller?.loadExternalSubtitle(from: url, usesOriginalStyle: false)
            })
            alert.addAction(UIAlertAction(title: mpvLocalized("common.cancel"), style: .cancel))
            controller.present(alert, animated: true)
        }
    }
}
