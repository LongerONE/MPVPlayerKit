import SnapKit
import MediaPlayer
import UIKit

/// Full-screen gestures supported by ``MPVQuickPlayerViewController``.
public struct MPVQuickPlayerGestureOptions: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let seeking = Self(rawValue: 1 << 0)
    public static let brightness = Self(rawValue: 1 << 1)
    public static let volume = Self(rawValue: 1 << 2)
    public static let all: Self = [.seeking, .brightness, .volume]
}

/// A ready-to-present UIKit player. Apps with their own controls can use `MPVPlayer` directly.
public final class MPVQuickPlayerViewController: UIViewController {
    public let player: MPVPlayer
    public var autoplay: Bool
    public var gestureOptions: MPVQuickPlayerGestureOptions = .all

    private let controlsView = UIView()
    private let playButton = UIButton(type: .system)
    private let progressSlider = UISlider()
    private let timeLabel = UILabel()
    private let audioButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let systemVolumeView = MPVolumeView(frame: .zero)
    private let gestureHUD = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let gestureHUDIcon = UIImageView()
    private let gestureHUDLabel = UILabel()
    private let gestureHUDProgress = UIProgressView(progressViewStyle: .default)
    private var isScrubbing = false
    private var panDirection: PanDirection = .none
    private var panStartLocation = CGPoint.zero
    private var panStartTime: TimeInterval = 0
    private var panTargetTime: TimeInterval = 0
    private var panStartBrightness: CGFloat = 0
    private var panStartVolume: Float = 0

    private enum PanDirection {
        case none
        case seeking
        case brightness
        case volume
    }

    public init(configuration: MPVPlayerConfiguration, autoplay: Bool = true) {
        player = MPVPlayer(configuration: configuration)
        self.autoplay = autoplay
        super.init(nibName: nil, bundle: nil)
        player.delegate = self
    }

    public convenience init(url: URL, autoplay: Bool = true) {
        self.init(
            configuration: MPVPlayerConfiguration(url: url),
            autoplay: autoplay
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        configureLayout()
        configureGestures()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if autoplay, player.isPlaying == false {
            player.play()
        }
    }

    private func configureViews() {
        view.backgroundColor = .black
        player.playbackView.backgroundColor = .black
        player.contentMode = .scaleAspectFit
        view.addSubview(player.playbackView)

        controlsView.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        view.addSubview(controlsView)

        playButton.tintColor = .white
        playButton.accessibilityLabel = "Play or pause"
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        controlsView.addSubview(playButton)

        progressSlider.minimumValue = 0
        progressSlider.minimumTrackTintColor = .systemBlue
        progressSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
        progressSlider.addTarget(self, action: #selector(beginScrubbing), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(updateScrubbingTime), for: .valueChanged)
        progressSlider.addTarget(
            self,
            action: #selector(endScrubbing),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        controlsView.addSubview(progressSlider)

        timeLabel.text = "00:00 / 00:00"
        timeLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        controlsView.addSubview(timeLabel)

        configureTrackButton(audioButton, title: "Audio", action: #selector(chooseAudioTrack))
        configureTrackButton(subtitleButton, title: "Subtitles", action: #selector(chooseSubtitleTrack))

        systemVolumeView.alpha = 0.001
        systemVolumeView.isUserInteractionEnabled = false
        view.addSubview(systemVolumeView)

        gestureHUD.alpha = 0
        gestureHUD.isUserInteractionEnabled = false
        gestureHUD.layer.cornerRadius = 12
        gestureHUD.clipsToBounds = true
        view.addSubview(gestureHUD)

        gestureHUDIcon.tintColor = .white
        gestureHUDIcon.contentMode = .scaleAspectFit
        gestureHUD.contentView.addSubview(gestureHUDIcon)

        gestureHUDLabel.textColor = .white
        gestureHUDLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        gestureHUDLabel.textAlignment = .center
        gestureHUD.contentView.addSubview(gestureHUDLabel)

        gestureHUDProgress.progressTintColor = .systemBlue
        gestureHUDProgress.trackTintColor = UIColor.white.withAlphaComponent(0.25)
        gestureHUD.contentView.addSubview(gestureHUDProgress)
    }

    private func configureTrackButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.addTarget(self, action: action, for: .touchUpInside)
        controlsView.addSubview(button)
    }

    private func configureLayout() {
        player.playbackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        controlsView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
        }
        playButton.snp.makeConstraints { make in
            make.leading.equalTo(controlsView.safeAreaLayoutGuide.snp.leading).offset(12)
            make.top.equalToSuperview().offset(10)
            make.size.equalTo(36)
        }
        progressSlider.snp.makeConstraints { make in
            make.leading.equalTo(playButton.snp.trailing).offset(8)
            make.centerY.equalTo(playButton)
            make.trailing.equalTo(controlsView.safeAreaLayoutGuide.snp.trailing).offset(-12)
        }
        timeLabel.snp.makeConstraints { make in
            make.leading.equalTo(progressSlider)
            make.top.equalTo(progressSlider.snp.bottom).offset(6)
            make.bottom.equalTo(controlsView.safeAreaLayoutGuide.snp.bottom).offset(-10)
        }
        subtitleButton.snp.makeConstraints { make in
            make.trailing.equalTo(progressSlider)
            make.centerY.equalTo(timeLabel)
        }
        audioButton.snp.makeConstraints { make in
            make.trailing.equalTo(subtitleButton.snp.leading).offset(-16)
            make.centerY.equalTo(timeLabel)
        }
        systemVolumeView.snp.makeConstraints { make in
            make.size.equalTo(1)
            make.leading.bottom.equalToSuperview()
        }
        gestureHUD.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.equalTo(220)
        }
        gestureHUDIcon.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(14)
            make.centerX.equalToSuperview()
            make.size.equalTo(24)
        }
        gestureHUDLabel.snp.makeConstraints { make in
            make.top.equalTo(gestureHUDIcon.snp.bottom).offset(8)
            make.leading.trailing.equalToSuperview().inset(12)
        }
        gestureHUDProgress.snp.makeConstraints { make in
            make.top.equalTo(gestureHUDLabel.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().offset(-14)
        }
    }

    private func configureGestures() {
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = self
        view.addGestureRecognizer(panGesture)
    }

    @objc private func togglePlayback() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    @objc private func beginScrubbing() {
        isScrubbing = true
    }

    @objc private func updateScrubbingTime() {
        timeLabel.text = Self.timeDescription(
            currentTime: TimeInterval(progressSlider.value),
            duration: player.duration
        )
    }

    @objc private func endScrubbing() {
        isScrubbing = false
        _ = player.seek(
            to: TimeInterval(progressSlider.value),
            autoPlay: player.isPlaying
        )
    }

    @objc private func chooseAudioTrack() {
        presentTrackPicker(type: .audio, sourceView: audioButton)
    }

    @objc private func chooseSubtitleTrack() {
        presentTrackPicker(type: .subtitle, sourceView: subtitleButton)
    }

    private func presentTrackPicker(type: MPVMediaTrackType, sourceView: UIView) {
        let tracks = player.tracks(ofType: type)
        let title = type == .audio ? "Audio Track" : "Subtitle Track"
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)

        if type == .subtitle {
            alert.addAction(UIAlertAction(title: "Off", style: .default) { [weak self] _ in
                self?.player.setSubtitlesVisible(false)
            })
        }
        for track in tracks {
            let marker = track.isSelected ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + track.name, style: .default) { [weak self] _ in
                self?.player.select(track: track)
                if type == .subtitle {
                    self?.player.setSubtitlesVisible(true)
                }
            })
        }
        if tracks.isEmpty {
            alert.message = "No tracks are currently available."
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = sourceView
        alert.popoverPresentationController?.sourceRect = sourceView.bounds
        present(alert, animated: true)
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
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

    private func lockedDirection(for translation: CGPoint) -> PanDirection {
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

    private func updatePan(translation: CGPoint) {
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

    private func showGestureHUD(icon: String, text: String, progress: Float) {
        gestureHUDIcon.image = UIImage(systemName: icon)
        gestureHUDLabel.text = text
        gestureHUDProgress.setProgress(min(max(progress, 0), 1), animated: false)
        if gestureHUD.alpha < 1 {
            UIView.animate(withDuration: 0.15) {
                self.gestureHUD.alpha = 1
            }
        }
    }

    private func finishPan() {
        panDirection = .none
        UIView.animate(withDuration: 0.2) {
            self.gestureHUD.alpha = 0
        }
    }

    private var systemVolumeSlider: UISlider? {
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

    private static func timeDescription(currentTime: TimeInterval, duration: TimeInterval) -> String {
        "\(clockDescription(currentTime)) / \(clockDescription(duration))"
    }

    private static func clockDescription(_ time: TimeInterval) -> String {
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

extension MPVQuickPlayerViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureOptions.isEmpty == false else { return false }
        let location = gestureRecognizer.location(in: view)
        guard controlsView.frame.contains(location) == false else { return false }
        guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = panGesture.velocity(in: view)
        return abs(velocity.x) > 1 || abs(velocity.y) > 1
    }
}

extension MPVQuickPlayerViewController: MPVPlayerDelegate {
    public func player(_ player: MPVPlayer, didChangeState state: MPVPlaybackState) {
        let isPlaying = state == .buffering || state == .readyToPlay || state == .bufferFinished
        playButton.setImage(UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"), for: .normal)
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
}
