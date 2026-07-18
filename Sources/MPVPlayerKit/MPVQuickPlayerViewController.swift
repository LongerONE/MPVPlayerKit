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
    public internal(set) var playbackRate = 1.0
    public internal(set) var videoQuality: MPVVideoQuality
    public internal(set) var debandEnabled: Bool
    public internal(set) var interpolationOptions: MPVInterpolationOptions
    public internal(set) var subtitleDelay: TimeInterval = 0
    public internal(set) var subtitleStyle = MPVSubtitleStyle.defaultStyle

    let topBar = UIView()
    let closeButton = UIButton(type: .system)
    let statusLabel = UILabel()
    let controlsView = UIView()
    let playButton = UIButton(type: .system)
    let progressSlider = UISlider()
    let timeLabel = UILabel()
    let trackButtonStack = UIStackView()
    let videoButton = UIButton(type: .system)
    let audioButton = UIButton(type: .system)
    let subtitleButton = UIButton(type: .system)
    let settingsButton = UIButton(type: .system)
    let loadingIndicator = UIActivityIndicatorView(style: .large)
    let systemVolumeView = MPVolumeView(frame: .zero)
    let gestureHUD = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    let gestureHUDIcon = UIImageView()
    let gestureHUDLabel = UILabel()
    let gestureHUDProgress = UIProgressView(progressViewStyle: .default)
    var isScrubbing = false
    var panDirection: PanDirection = .none
    var panStartLocation = CGPoint.zero
    var panStartTime: TimeInterval = 0
    var panTargetTime: TimeInterval = 0
    var panStartBrightness: CGFloat = 0
    var panStartVolume: Float = 0
    var playbackState = MPVPlaybackState.paused
    var decoderMode = MPVDecoderMode.initializing
    var bufferingProgress = 0
    var pendingSubtitleRequestID: UUID?
    var isCancellingSubtitleLoad = false

    enum PanDirection {
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

    func configureViews() {
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

    func configureControlButton(
        _ button: UIButton,
        symbol: String,
        label: String,
        action: Selector
    ) {
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = label
        trackButtonStack.addArrangedSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    func configureLayout() {
        let constrainedViews = [
            player.playbackView,
            topBar,
            closeButton,
            statusLabel,
            loadingIndicator,
            controlsView,
            playButton,
            progressSlider,
            timeLabel,
            trackButtonStack,
            systemVolumeView,
            gestureHUD,
            gestureHUDIcon,
            gestureHUDLabel,
            gestureHUDProgress,
        ]
        constrainedViews.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let topSafeArea = topBar.safeAreaLayoutGuide
        let controlsSafeArea = controlsView.safeAreaLayoutGuide
        let hudContentView = gestureHUD.contentView
        NSLayoutConstraint.activate([
            player.playbackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            player.playbackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            player.playbackView.topAnchor.constraint(equalTo: view.topAnchor),
            player.playbackView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: view.topAnchor),

            closeButton.leadingAnchor.constraint(equalTo: topSafeArea.leadingAnchor, constant: 12),
            closeButton.topAnchor.constraint(equalTo: topSafeArea.topAnchor, constant: 8),
            closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: topSafeArea.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            controlsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            playButton.leadingAnchor.constraint(equalTo: controlsSafeArea.leadingAnchor, constant: 12),
            playButton.topAnchor.constraint(equalTo: controlsView.topAnchor, constant: 10),
            playButton.widthAnchor.constraint(equalToConstant: 36),
            playButton.heightAnchor.constraint(equalToConstant: 36),

            progressSlider.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 8),
            progressSlider.trailingAnchor.constraint(equalTo: controlsSafeArea.trailingAnchor, constant: -12),
            progressSlider.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),

            timeLabel.leadingAnchor.constraint(equalTo: progressSlider.leadingAnchor),
            timeLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 6),
            timeLabel.bottomAnchor.constraint(equalTo: controlsSafeArea.bottomAnchor, constant: -10),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: trackButtonStack.leadingAnchor, constant: -12),

            trackButtonStack.trailingAnchor.constraint(equalTo: progressSlider.trailingAnchor),
            trackButtonStack.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),

            systemVolumeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            systemVolumeView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            systemVolumeView.widthAnchor.constraint(equalToConstant: 1),
            systemVolumeView.heightAnchor.constraint(equalToConstant: 1),

            gestureHUD.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gestureHUD.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            gestureHUD.widthAnchor.constraint(equalToConstant: 220),

            gestureHUDIcon.topAnchor.constraint(equalTo: hudContentView.topAnchor, constant: 14),
            gestureHUDIcon.centerXAnchor.constraint(equalTo: hudContentView.centerXAnchor),
            gestureHUDIcon.widthAnchor.constraint(equalToConstant: 24),
            gestureHUDIcon.heightAnchor.constraint(equalToConstant: 24),

            gestureHUDLabel.topAnchor.constraint(equalTo: gestureHUDIcon.bottomAnchor, constant: 8),
            gestureHUDLabel.leadingAnchor.constraint(equalTo: hudContentView.leadingAnchor, constant: 12),
            gestureHUDLabel.trailingAnchor.constraint(equalTo: hudContentView.trailingAnchor, constant: -12),

            gestureHUDProgress.topAnchor.constraint(equalTo: gestureHUDLabel.bottomAnchor, constant: 10),
            gestureHUDProgress.leadingAnchor.constraint(equalTo: hudContentView.leadingAnchor, constant: 16),
            gestureHUDProgress.trailingAnchor.constraint(equalTo: hudContentView.trailingAnchor, constant: -16),
            gestureHUDProgress.bottomAnchor.constraint(equalTo: hudContentView.bottomAnchor, constant: -14),
        ])
    }

    func configureGestures() {
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

}
