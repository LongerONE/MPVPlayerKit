import SnapKit
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

extension MPVQuickPlayerViewController {
    @objc func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .began:
            panDirection = .none
            panStartLocation = gesture.location(in: view)
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

        if panStartLocation.x < view.bounds.midX, gestureOptions.contains(.brightness) {
            return .brightness
        }
        if panStartLocation.x >= view.bounds.midX, gestureOptions.contains(.volume) {
            return .volume
        }
        return .none
    }

    func updatePan(translation: CGPoint) {
        switch panDirection {
        case .seeking:
            let delta = Self.seekTimeDelta(
                translationX: translation.x,
                viewWidth: view.bounds.width,
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
                viewHeight: view.bounds.height
            )
            UIScreen.main.brightness = value
            showGestureHUD(icon: "sun.max.fill", text: "\(Int((value * 100).rounded()))%", progress: Float(value))
        case .volume:
            let value = Float(Self.verticalValue(
                startValue: CGFloat(panStartVolume),
                translationY: translation.y,
                viewHeight: view.bounds.height
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

    static func videoQualityTitle(_ quality: MPVVideoQuality) -> String {
        switch quality {
        case .powerSaving: "Power Saver"
        case .balanced: "Balanced"
        case .highQuality: "High Quality"
        }
    }

    static func interpolationTitle(_ quality: MPVInterpolationQuality) -> String {
        switch quality {
        case .off: "Off"
        case .standard: "Standard"
        case .smooth: "Smooth"
        case .highQuality: "High Quality"
        }
    }

    static func delayTitle(_ delay: TimeInterval) -> String {
        if abs(delay) < 0.001 { return "0s" }
        return String(format: "%+.2gs", delay)
    }

    func updateStatusLabel() {
        let stateTitle: String
        switch playbackState {
        case .buffering: stateTitle = "Buffering \(bufferingProgress)%"
        case .readyToPlay: stateTitle = "Ready"
        case .bufferFinished: stateTitle = "Playing"
        case .paused: stateTitle = "Paused"
        case .playedToTheEnd: stateTitle = "Finished"
        case .error: stateTitle = "Playback Error"
        }
        let decoderTitle: String
        switch decoderMode {
        case .initializing: decoderTitle = "Decoder initializing"
        case .hardware: decoderTitle = "Hardware decoding"
        case .software: decoderTitle = "Software decoding"
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
