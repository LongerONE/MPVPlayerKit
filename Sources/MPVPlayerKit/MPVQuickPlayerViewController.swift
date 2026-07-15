import SnapKit
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

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
    public private(set) var playbackRate = 1.0
    public private(set) var videoQuality: MPVVideoQuality
    public private(set) var debandEnabled: Bool
    public private(set) var interpolationOptions: MPVInterpolationOptions
    public private(set) var subtitleDelay: TimeInterval = 0
    public private(set) var subtitleStyle = MPVSubtitleStyle.defaultStyle

    private let topBar = UIView()
    private let closeButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let controlsView = UIView()
    private let playButton = UIButton(type: .system)
    private let progressSlider = UISlider()
    private let timeLabel = UILabel()
    private let trackButtonStack = UIStackView()
    private let videoButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let subtitleButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let loadingIndicator = UIActivityIndicatorView(style: .large)
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
    private var playbackState = MPVPlaybackState.paused
    private var decoderMode = MPVDecoderMode.initializing
    private var bufferingProgress = 0
    private var pendingSubtitleRequestID: UUID?
    private var isCancellingSubtitleLoad = false

    private enum PanDirection {
        case none
        case seeking
        case brightness
        case volume
    }

    public init(configuration: MPVPlayerConfiguration, autoplay: Bool = true) {
        player = MPVPlayer(configuration: configuration)
        self.autoplay = autoplay
        videoQuality = configuration.videoQuality
        debandEnabled = configuration.debandEnabled
        interpolationOptions = configuration.interpolationOptions
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

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            player.stop()
        }
    }

    private func configureViews() {
        view.backgroundColor = .black
        player.playbackView.backgroundColor = .black
        player.contentMode = .scaleAspectFit
        view.addSubview(player.playbackView)

        topBar.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        view.addSubview(topBar)

        closeButton.tintColor = .white
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.accessibilityLabel = "Close player"
        closeButton.addTarget(self, action: #selector(closePlayer), for: .touchUpInside)
        topBar.addSubview(closeButton)

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textAlignment = .right
        statusLabel.accessibilityIdentifier = "MPVQuickPlayer.statusLabel"
        topBar.addSubview(statusLabel)

        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.accessibilityLabel = "Loading video"
        loadingIndicator.accessibilityIdentifier = "MPVQuickPlayer.loadingIndicator"
        view.addSubview(loadingIndicator)

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

        trackButtonStack.axis = .horizontal
        trackButtonStack.alignment = .center
        trackButtonStack.spacing = 14
        controlsView.addSubview(trackButtonStack)

        configureControlButton(videoButton, symbol: "film", label: "Video track", action: #selector(chooseVideoTrack))
        configureControlButton(audioButton, symbol: "waveform", label: "Audio track", action: #selector(chooseAudioTrack))
        configureControlButton(subtitleButton, symbol: "captions.bubble", label: "Subtitles", action: #selector(chooseSubtitleTrack))
        configureControlButton(settingsButton, symbol: "gearshape", label: "Playback settings", action: #selector(showSettings))

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
        updateStatusLabel()
    }

    private func configureControlButton(
        _ button: UIButton,
        symbol: String,
        label: String,
        action: Selector
    ) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = label
        trackButtonStack.addArrangedSubview(button)
        button.snp.makeConstraints { make in
            make.size.equalTo(32)
        }
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func configureLayout() {
        player.playbackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        topBar.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
        }
        closeButton.snp.makeConstraints { make in
            make.leading.equalTo(topBar.safeAreaLayoutGuide.snp.leading).offset(12)
            make.bottom.equalToSuperview().offset(-8)
            make.size.equalTo(36)
            make.top.equalTo(topBar.safeAreaLayoutGuide.snp.top).offset(8)
        }
        statusLabel.snp.makeConstraints { make in
            make.leading.greaterThanOrEqualTo(closeButton.snp.trailing).offset(12)
            make.trailing.equalTo(topBar.safeAreaLayoutGuide.snp.trailing).offset(-12)
            make.centerY.equalTo(closeButton)
        }
        loadingIndicator.snp.makeConstraints { make in
            make.center.equalToSuperview()
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
            make.trailing.lessThanOrEqualTo(trackButtonStack.snp.leading).offset(-12)
        }
        trackButtonStack.snp.makeConstraints { make in
            make.trailing.equalTo(progressSlider)
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

    @objc private func closePlayer() {
        player.stop()
        if let navigationController,
           navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
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

    @objc private func chooseVideoTrack() {
        presentTrackPicker(type: .video, sourceView: videoButton)
    }

    @objc private func chooseSubtitleTrack() {
        presentTrackPicker(type: .subtitle, sourceView: subtitleButton)
    }

    @objc private func showSettings() {
        let alert = actionSheet(title: "Playback Settings", sourceView: settingsButton)
        alert.addAction(UIAlertAction(title: "Playback Speed · \(Self.rateTitle(playbackRate))", style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showPlaybackRatePicker() }
        })
        alert.addAction(UIAlertAction(title: "Video Quality · \(Self.videoQualityTitle(videoQuality))", style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showVideoQualityPicker() }
        })
        alert.addAction(UIAlertAction(title: "Frame Interpolation · \(Self.interpolationTitle(interpolationOptions.quality))", style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showInterpolationPicker() }
        })
        let debandTitle = debandEnabled ? "Disable Debanding" : "Enable Debanding"
        alert.addAction(UIAlertAction(title: debandTitle, style: .default) { [weak self] _ in
            guard let self else { return }
            setDebandEnabled(debandEnabled == false)
        })
        let contentModeTitle = player.contentMode == .scaleAspectFill ? "Fit Video" : "Fill Screen"
        alert.addAction(UIAlertAction(title: contentModeTitle, style: .default) { [weak self] _ in
            guard let self else { return }
            player.contentMode = player.contentMode == .scaleAspectFill ? .scaleAspectFit : .scaleAspectFill
        })
        alert.addAction(UIAlertAction(title: "Subtitle Delay · \(Self.delayTitle(subtitleDelay))", style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showSubtitleDelayPicker() }
        })
        alert.addAction(UIAlertAction(title: "Subtitle Style", style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showSubtitleStylePicker() }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    public func setPlaybackRate(_ rate: Double) {
        let normalizedRate = min(max(rate, 0.25), 4.0)
        playbackRate = normalizedRate
        player.setPlaybackRate(normalizedRate)
        updateStatusLabel()
    }

    public func setVideoQuality(_ quality: MPVVideoQuality) {
        videoQuality = quality
        player.updateVideoQuality(quality)
    }

    public func setDebandEnabled(_ enabled: Bool) {
        debandEnabled = enabled
        player.updateVideoRenderOptions(
            debandEnabled: enabled,
            interpolationOptions: interpolationOptions
        )
    }

    public func setInterpolationOptions(_ options: MPVInterpolationOptions) {
        interpolationOptions = options
        player.updateVideoRenderOptions(
            debandEnabled: debandEnabled,
            interpolationOptions: options
        )
    }

    public func setSubtitleDelay(_ delay: TimeInterval) {
        guard delay.isFinite else { return }
        subtitleDelay = min(max(delay, -60), 60)
        player.setSubtitleDelay(subtitleDelay)
    }

    public func setSubtitleStyle(_ style: MPVSubtitleStyle) {
        subtitleStyle = style
        player.updateSubtitleStyle(style)
    }

    private func showPlaybackRatePicker() {
        let alert = actionSheet(title: "Playback Speed", sourceView: settingsButton)
        [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4].forEach { rate in
            let marker = abs(rate - playbackRate) < 0.001 ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + Self.rateTitle(rate), style: .default) { [weak self] _ in
                self?.setPlaybackRate(rate)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showVideoQualityPicker() {
        let alert = actionSheet(title: "Video Quality", sourceView: settingsButton)
        [MPVVideoQuality.powerSaving, .balanced, .highQuality].forEach { quality in
            let marker = quality == videoQuality ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + Self.videoQualityTitle(quality), style: .default) { [weak self] _ in
                self?.setVideoQuality(quality)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showInterpolationPicker() {
        let alert = actionSheet(title: "Frame Interpolation", sourceView: settingsButton)
        MPVInterpolationQuality.allCases.forEach { quality in
            let marker = quality == interpolationOptions.quality ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + Self.interpolationTitle(quality), style: .default) { [weak self] _ in
                guard let self else { return }
                setInterpolationOptions(MPVInterpolationOptions(quality: quality))
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showSubtitleDelayPicker() {
        let alert = actionSheet(title: "Subtitle Delay", sourceView: settingsButton)
        [-2.0, -1, -0.5, 0, 0.5, 1, 2].forEach { delay in
            let marker = abs(delay - subtitleDelay) < 0.001 ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + Self.delayTitle(delay), style: .default) { [weak self] _ in
                self?.setSubtitleDelay(delay)
            })
        }
        alert.addAction(UIAlertAction(title: "Custom…", style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showCustomSubtitleDelayPrompt() }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showCustomSubtitleDelayPrompt() {
        let alert = UIAlertController(
            title: "Subtitle Delay",
            message: "Enter seconds from -60 to 60. Positive values delay subtitles.",
            preferredStyle: .alert
        )
        alert.addTextField { [subtitleDelay] field in
            field.keyboardType = .numbersAndPunctuation
            field.text = String(format: "%.2f", subtitleDelay)
        }
        alert.addAction(UIAlertAction(title: "Apply", style: .default) { [weak self, weak alert] _ in
            guard let value = alert?.textFields?.first?.text.flatMap(Double.init) else { return }
            self?.setSubtitleDelay(value)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func showSubtitleStylePicker() {
        let alert = actionSheet(title: "Subtitle Style", sourceView: settingsButton)
        let styles: [(String, MPVSubtitleStyle)] = [
            ("Default", .defaultStyle),
            ("Large", .large),
            ("High Contrast", .highContrast),
        ]
        styles.forEach { title, style in
            let marker = style == subtitleStyle ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + title, style: .default) { [weak self] _ in
                self?.setSubtitleStyle(style)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func actionSheet(title: String, sourceView: UIView) -> UIAlertController {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        alert.popoverPresentationController?.sourceView = sourceView
        alert.popoverPresentationController?.sourceRect = sourceView.bounds
        return alert
    }

    private func presentAfterCurrentSheet(_ presentation: @escaping (MPVQuickPlayerViewController) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            presentation(self)
        }
    }

    private func presentTrackPicker(type: MPVMediaTrackType, sourceView: UIView) {
        let tracks = player.tracks(ofType: type)
        let title: String
        switch type {
        case .video: title = "Video Track"
        case .audio: title = "Audio Track"
        case .subtitle: title = "Subtitle Track"
        }
        let alert = actionSheet(title: title, sourceView: sourceView)

        if type == .subtitle {
            alert.addAction(UIAlertAction(title: "Off", style: .default) { [weak self] _ in
                self?.player.setSubtitlesVisible(false)
            })
            alert.addAction(UIAlertAction(title: "Load External Subtitle…", style: .default) { [weak self] _ in
                self?.presentAfterCurrentSheet { $0.presentExternalSubtitlePicker() }
            })
            if pendingSubtitleRequestID != nil {
                alert.addAction(UIAlertAction(title: "Cancel Subtitle Load", style: .destructive) { [weak self] _ in
                    self?.cancelExternalSubtitleLoad()
                })
            }
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
        present(alert, animated: true)
    }

    private func presentExternalSubtitlePicker() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.text, .data],
            asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func loadExternalSubtitle(from url: URL, usesOriginalStyle: Bool) {
        loadingIndicator.startAnimating()
        statusLabel.text = "Loading subtitle…"
        pendingSubtitleRequestID = player.loadExternalSubtitle(
            from: url,
            usesOriginalStyle: usesOriginalStyle
        ) { [weak self] success in
            guard let self else { return }
            pendingSubtitleRequestID = nil
            if Self.shouldShowLoading(for: playbackState) {
                loadingIndicator.startAnimating()
            } else {
                loadingIndicator.stopAnimating()
            }
            if success {
                player.setSubtitlesVisible(true)
                updateStatusLabel()
            } else if isCancellingSubtitleLoad == false {
                presentMessage(title: "Subtitle Error", message: "The external subtitle could not be loaded.")
            }
            isCancellingSubtitleLoad = false
        }
    }

    private func cancelExternalSubtitleLoad() {
        guard let requestID = pendingSubtitleRequestID else { return }
        isCancellingSubtitleLoad = true
        player.cancelExternalSubtitleLoad(requestID)
        pendingSubtitleRequestID = nil
        updateStatusLabel()
    }

    private func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
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

    private func updateStatusLabel() {
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
            presentMessage(title: "Playback Error", message: "The video could not be played.")
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
            let alert = controller.actionSheet(title: "Subtitle Style", sourceView: controller.subtitleButton)
            alert.addAction(UIAlertAction(title: "Use Subtitle File Style", style: .default) { [weak controller] _ in
                controller?.loadExternalSubtitle(from: url, usesOriginalStyle: true)
            })
            alert.addAction(UIAlertAction(title: "Use Player Style", style: .default) { [weak controller] _ in
                controller?.loadExternalSubtitle(from: url, usesOriginalStyle: false)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            controller.present(alert, animated: true)
        }
    }
}
