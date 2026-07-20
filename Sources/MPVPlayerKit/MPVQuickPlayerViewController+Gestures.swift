import MediaPlayer
import UIKit
import UniformTypeIdentifiers

extension MPVQuickPlayerViewController {
    @objc func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: contentView)

        switch gesture.state {
        case .began:
            panDirection = .none
            panStartLocation = gesture.location(in: contentView)
            panStartTime = player.currentTime
            panTargetTime = panStartTime
            panStartBrightness = UIScreen.main.brightness
            panStartVolume = systemVolumeSlider?.value ?? 0
        case .changed:
            if panDirection == .none {
                panDirection = lockedDirection(for: translation)
            }
            updatePan(translation: translation)
        case .ended:
            if panDirection == .seeking {
                _ = player.seek(to: panTargetTime, autoPlay: player.isPlaying)
            }
            finishPan()
        case .cancelled, .failed:
            finishPan()
        default:
            break
        }
    }

    func lockedDirection(for translation: CGPoint) -> PanDirection {
        let horizontalDistance = abs(translation.x)
        let verticalDistance = abs(translation.y)
        guard max(horizontalDistance, verticalDistance) >= 10 else { return .none }

        if horizontalDistance >= verticalDistance * 1.25,
           gestureOptions.contains(.seeking),
           player.duration.isFinite,
           player.duration > 0 {
            return .seeking
        }
        guard verticalDistance >= horizontalDistance * 1.25 else { return .none }

        if panStartLocation.x < contentView.bounds.midX, gestureOptions.contains(.brightness) {
            return .brightness
        }
        if panStartLocation.x >= contentView.bounds.midX, gestureOptions.contains(.volume) {
            return .volume
        }
        return .none
    }

    func updatePan(translation: CGPoint) {
        switch panDirection {
        case .seeking:
            let delta = Self.seekTimeDelta(
                translationX: translation.x,
                viewWidth: contentView.bounds.width,
                duration: player.duration
            )
            panTargetTime = min(max(panStartTime + delta, 0), player.duration)
            let progress = Float(panTargetTime / max(player.duration, 1))
            showGestureHUD(
                icon: translation.x >= 0 ? "goforward" : "gobackward",
                text: Self.timeDescription(currentTime: panTargetTime, duration: player.duration),
                progress: progress
            )
        case .brightness:
            let value = Self.verticalValue(
                startValue: panStartBrightness,
                translationY: translation.y,
                viewHeight: contentView.bounds.height
            )
            UIScreen.main.brightness = value
            showGestureHUD(icon: "sun.max.fill", text: "\(Int((value * 100).rounded()))%", progress: Float(value))
        case .volume:
            let value = Float(Self.verticalValue(
                startValue: CGFloat(panStartVolume),
                translationY: translation.y,
                viewHeight: contentView.bounds.height
            ))
            systemVolumeSlider?.setValue(value, animated: false)
            systemVolumeSlider?.sendActions(for: .valueChanged)
            let icon = value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
            showGestureHUD(icon: icon, text: "\(Int((value * 100).rounded()))%", progress: value)
        case .none:
            break
        }
    }

    func showGestureHUD(icon: String, text: String, progress: Float) {
        gestureHUDIcon.image = UIImage(systemName: icon)
        gestureHUDLabel.text = text
        gestureHUDProgress.setProgress(min(max(progress, 0), 1), animated: false)
        if gestureHUD.alpha < 1 {
            UIView.animate(withDuration: 0.15) {
                self.gestureHUD.alpha = 1
            }
        }
    }

    func finishPan() {
        panDirection = .none
        UIView.animate(withDuration: 0.2) {
            self.gestureHUD.alpha = 0
        }
    }

    var systemVolumeSlider: UISlider? {
        func slider(in view: UIView) -> UISlider? {
            if let slider = view as? UISlider { return slider }
            for subview in view.subviews {
                if let slider = slider(in: subview) {
                    return slider
                }
            }
            return nil
        }
        return slider(in: systemVolumeView)
    }

    static func seekTimeDelta(
        translationX: CGFloat,
        viewWidth: CGFloat,
        duration: TimeInterval
    ) -> TimeInterval {
        guard duration.isFinite, duration > 0, viewWidth > 0 else { return 0 }
        let secondsPerScreen = min(max(duration * 0.1, 60), 600)
        return TimeInterval(translationX / viewWidth) * secondsPerScreen
    }

    static func verticalValue(
        startValue: CGFloat,
        translationY: CGFloat,
        viewHeight: CGFloat
    ) -> CGFloat {
        let effectiveHeight = max(viewHeight * 0.5, 160)
        return min(max(startValue - translationY / effectiveHeight, 0), 1)
    }

    static func shouldShowLoading(for state: MPVPlaybackState) -> Bool {
        state == .buffering
    }

    static func rateTitle(_ rate: Double) -> String {
        var value = String(format: "%.2f", rate)
        while value.last == "0" { value.removeLast() }
        if value.last == "." { value.removeLast() }
        return value + "×"
    }

    static func videoQualityTitle(
        _ quality: MPVVideoQuality,
        localization: String? = nil
    ) -> String {
        let key = switch quality {
        case .powerSaving: "quality.power_saver"
        case .balanced: "quality.balanced"
        case .highQuality: "quality.high"
        }
        return localizedTitle(key, localization: localization)
    }

    static func interpolationTitle(
        _ quality: MPVInterpolationQuality,
        localization: String? = nil
    ) -> String {
        let key = switch quality {
        case .off: "interpolation.off"
        case .standard: "interpolation.standard"
        case .smooth: "interpolation.smooth"
        case .highQuality: "interpolation.high"
        }
        return localizedTitle(key, localization: localization)
    }

    static func delayTitle(
        _ delay: TimeInterval,
        localization: String? = nil
    ) -> String {
        let localization = localization ?? MPVLocalization.localizationIdentifier()
        if abs(delay) < 0.001 {
            return MPVLocalization.string("subtitle.delay.zero", localization: localization)
        }
        return MPVLocalization.string(
            "subtitle.delay.format",
            localization: localization,
            arguments: [delay]
        )
    }

    private static func localizedTitle(
        _ key: String,
        localization: String?
    ) -> String {
        guard let localization else { return mpvLocalized(key) }
        return MPVLocalization.string(key, localization: localization)
    }

    func updateStatusLabel() {
        let stateTitle: String
        switch playbackState {
        case .buffering: stateTitle = mpvLocalized("status.buffering", bufferingProgress)
        case .readyToPlay: stateTitle = mpvLocalized("status.ready")
        case .bufferFinished: stateTitle = mpvLocalized("status.playing")
        case .paused: stateTitle = mpvLocalized("status.paused")
        case .playedToTheEnd: stateTitle = mpvLocalized("status.finished")
        case .error: stateTitle = mpvLocalized("status.playback_error")
        }
        let decoderTitle: String
        switch decoderMode {
        case .initializing: decoderTitle = mpvLocalized("status.decoder_initializing")
        case .hardware: decoderTitle = mpvLocalized("status.hardware_decoding")
        case .software: decoderTitle = mpvLocalized("status.software_decoding")
        }
        statusLabel.text = "\(stateTitle) · \(decoderTitle) · \(Self.rateTitle(playbackRate))"
    }

    static func timeDescription(currentTime: TimeInterval, duration: TimeInterval) -> String {
        "\(clockDescription(currentTime)) / \(clockDescription(duration))"
    }

    static func clockDescription(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "00:00" }
        let seconds = Int(time.rounded(.down))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
