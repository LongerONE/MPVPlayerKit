import AVFoundation
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
    public internal(set) var isLandscapeForced: Bool
    public internal(set) var playbackRate = 1.0
    public internal(set) var videoQuality: MPVVideoQuality
    public internal(set) var debandEnabled: Bool
    public internal(set) var interpolationOptions: MPVInterpolationOptions
    public internal(set) var subtitleDelay: TimeInterval = 0
    public internal(set) var subtitleStyle = MPVSubtitleStyle.defaultStyle

    let contentView = UIView()
    let topBar = UIView()
    let closeButton = UIButton(type: .system)
    let orientationButton = UIButton(type: .system)
    let statusLabel = UILabel()
    let controlsView = UIView()
    let backwardButton = UIButton(type: .system)
    let playButton = UIButton(type: .system)
    let forwardButton = UIButton(type: .system)
    let transportStack = UIStackView()
    let progressSlider = UISlider()
    let timeLabel = UILabel()
    let trackButtonStack = UIStackView()
    let videoButton = UIButton(type: .system)
    let audioButton = UIButton(type: .system)
    let subtitleButton = UIButton(type: .system)
    let pictureInPictureButton = UIButton(type: .system)
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
    var idleTimerDisabledBeforePlayback: Bool?
    var decoderMode = MPVDecoderMode.initializing
    var bufferingProgress = 0
    var pendingSubtitleRequestID: UUID?
    var isCancellingSubtitleLoad = false
    var isUsingManualLandscape: Bool
    weak var orientationSynchronizedPresentedViewController: UIViewController?
    weak var actionSheetOverlay: MPVQuickPlayerMenuView?
    var arePlaybackControlsHidden = false
    var closeButtonLeadingConstraint: NSLayoutConstraint!
    var statusLabelTrailingConstraint: NSLayoutConstraint!
    var transportStackLeadingConstraint: NSLayoutConstraint!
    var progressSliderTrailingConstraint: NSLayoutConstraint!
    var closeButtonTopSafeAreaConstraint: NSLayoutConstraint!
    var closeButtonTopEdgeConstraint: NSLayoutConstraint!
    var trackButtonStackBottomSafeAreaConstraint: NSLayoutConstraint!
    var trackButtonStackBottomEdgeConstraint: NSLayoutConstraint!
    var regularPlaybackControlLayoutConstraints = [NSLayoutConstraint]()
    var compactPlaybackControlLayoutConstraints = [NSLayoutConstraint]()

    enum PanDirection {
        case none
        case seeking
        case brightness
        case volume
    }

    public init(
        configuration: MPVPlayerConfiguration,
        autoplay: Bool = true,
        forceLandscape: Bool = false
    ) {
        player = MPVPlayer(configuration: configuration)
        self.autoplay = autoplay
        isLandscapeForced = forceLandscape
        isUsingManualLandscape = forceLandscape && Self.applicationSupportsLandscape == false
        videoQuality = configuration.videoQuality
        debandEnabled = configuration.debandEnabled
        interpolationOptions = configuration.interpolationOptions
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
        player.delegate = self
    }

    public convenience init(
        url: URL,
        autoplay: Bool = true,
        forceLandscape: Bool = false
    ) {
        self.init(
            configuration: MPVPlayerConfiguration(url: url),
            autoplay: autoplay,
            forceLandscape: forceLandscape
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override var shouldAutorotate: Bool {
        true
    }

    public override var prefersStatusBarHidden: Bool {
        true
    }

    public override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        .fade
    }

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if isUsingManualLandscape {
            return .portrait
        }
        return isLandscapeForced ? .landscapeRight : .all
    }

    public override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        isLandscapeForced && isUsingManualLandscape == false ? .landscapeRight : .portrait
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        configureLayout()
        configureGestures()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyPreferredOrientationIfNeeded()
        updateIdleTimer(for: playbackState)
        if autoplay, player.isPlaying == false {
            player.play()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutOrientationContentView()
        layoutPresentedViewControllerInPlayerOrientation()
        updatePlaybackControlSafeAreaInsets()
        actionSheetOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
    }

    public override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updatePlaybackControlSafeAreaInsets()
        actionSheetOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        restoreIdleTimer()
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            player.stop()
        }
    }

    func configureViews() {
        view.backgroundColor = .black
        contentView.backgroundColor = .black
        view.addSubview(contentView)
        player.playbackView.backgroundColor = .black
        player.contentMode = .scaleAspectFit
        contentView.addSubview(player.playbackView)

        topBar.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        contentView.addSubview(topBar)

        closeButton.tintColor = .white
        closeButton.setImage(MPVQuickPlayerSymbol.image(.close, pointSize: 16), for: .normal)
        closeButton.accessibilityLabel = mpvLocalized("accessibility.close_player")
        closeButton.addTarget(self, action: #selector(closePlayer), for: .touchUpInside)
        topBar.addSubview(closeButton)

        orientationButton.tintColor = .white
        orientationButton.setImage(
            MPVQuickPlayerSymbol.image(.forceLandscape, pointSize: 18),
            for: .normal
        )
        orientationButton.accessibilityLabel = mpvLocalized("accessibility.force_landscape")
        orientationButton.accessibilityIdentifier = "MPVQuickPlayer.orientationButton"
        orientationButton.addTarget(self, action: #selector(toggleForcedLandscape), for: .touchUpInside)
        topBar.addSubview(orientationButton)
        updateOrientationButton()

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textAlignment = .right
        statusLabel.accessibilityIdentifier = "MPVQuickPlayer.statusLabel"
        topBar.addSubview(statusLabel)

        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.accessibilityLabel = mpvLocalized("accessibility.loading_video")
        loadingIndicator.accessibilityIdentifier = "MPVQuickPlayer.loadingIndicator"
        contentView.addSubview(loadingIndicator)

        controlsView.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        contentView.addSubview(controlsView)

        configureTransportControls()

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
        trackButtonStack.spacing = 8
        controlsView.addSubview(trackButtonStack)

        configureControlButton(
            videoButton,
            symbol: .videoTrack,
            label: mpvLocalized("accessibility.video_track"),
            action: #selector(chooseVideoTrack)
        )
        configureControlButton(
            audioButton,
            symbol: .audioTrack,
            label: mpvLocalized("accessibility.audio_track"),
            action: #selector(chooseAudioTrack)
        )
        configureControlButton(
            subtitleButton,
            symbol: .subtitles,
            label: mpvLocalized("accessibility.subtitles"),
            action: #selector(chooseSubtitleTrack)
        )
        configureControlButton(
            pictureInPictureButton,
            symbol: .pictureInPictureEnter,
            label: mpvLocalized("accessibility.picture_in_picture"),
            action: #selector(startPictureInPicture)
        )
        pictureInPictureButton.accessibilityIdentifier =
            "MPVQuickPlayer.pictureInPictureButton"
        pictureInPictureButton.isEnabled = player.isPictureInPictureSupported
        updatePictureInPictureButton(isActive: player.isPictureInPictureActive)
        configureControlButton(
            settingsButton,
            symbol: .settings,
            label: mpvLocalized("accessibility.playback_settings"),
            action: #selector(showSettings)
        )

        systemVolumeView.alpha = 0.001
        systemVolumeView.isUserInteractionEnabled = false
        contentView.addSubview(systemVolumeView)

        gestureHUD.alpha = 0
        gestureHUD.isUserInteractionEnabled = false
        gestureHUD.layer.cornerRadius = 12
        gestureHUD.clipsToBounds = true
        contentView.addSubview(gestureHUD)

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

    func configureLayout() {
        let constrainedViews = [
            player.playbackView,
            topBar,
            closeButton,
            orientationButton,
            statusLabel,
            loadingIndicator,
            controlsView,
            transportStack,
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
        closeButtonLeadingConstraint = closeButton.leadingAnchor.constraint(
            equalTo: topBar.leadingAnchor,
            constant: 12
        )
        statusLabelTrailingConstraint = statusLabel.trailingAnchor.constraint(
            equalTo: topBar.trailingAnchor,
            constant: -12
        )
        transportStackLeadingConstraint = transportStack.leadingAnchor.constraint(
            equalTo: controlsView.leadingAnchor,
            constant: 12
        )
        progressSliderTrailingConstraint = progressSlider.trailingAnchor.constraint(
            equalTo: controlsView.trailingAnchor,
            constant: -12
        )
        closeButtonTopSafeAreaConstraint = closeButton.topAnchor.constraint(
            equalTo: topSafeArea.topAnchor,
            constant: 8
        )
        closeButtonTopEdgeConstraint = closeButton.topAnchor.constraint(
            equalTo: topBar.topAnchor,
            constant: 8
        )
        trackButtonStackBottomSafeAreaConstraint = trackButtonStack.bottomAnchor.constraint(
            equalTo: controlsSafeArea.bottomAnchor,
            constant: -10
        )
        trackButtonStackBottomEdgeConstraint = trackButtonStack.bottomAnchor.constraint(
            equalTo: controlsView.bottomAnchor,
            constant: -10
        )
        closeButtonTopSafeAreaConstraint.isActive = isUsingManualLandscape == false
        closeButtonTopEdgeConstraint.isActive = isUsingManualLandscape
        trackButtonStackBottomSafeAreaConstraint.isActive = isUsingManualLandscape == false
        trackButtonStackBottomEdgeConstraint.isActive = isUsingManualLandscape
        regularPlaybackControlLayoutConstraints = [
            timeLabel.trailingAnchor.constraint(equalTo: progressSlider.trailingAnchor),
            trackButtonStack.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 6),
            trackButtonStack.centerXAnchor.constraint(equalTo: controlsView.centerXAnchor),
            trackButtonStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: timeLabel.leadingAnchor
            ),
            trackButtonStack.trailingAnchor.constraint(
                lessThanOrEqualTo: timeLabel.trailingAnchor
            ),
        ]
        compactPlaybackControlLayoutConstraints = [
            timeLabel.trailingAnchor.constraint(equalTo: trackButtonStack.leadingAnchor, constant: -8),
            trackButtonStack.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            trackButtonStack.trailingAnchor.constraint(equalTo: progressSlider.trailingAnchor),
        ]
        NSLayoutConstraint.activate([
            player.playbackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            player.playbackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            player.playbackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            player.playbackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor),

            closeButtonLeadingConstraint,
            closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            orientationButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            orientationButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            orientationButton.widthAnchor.constraint(equalToConstant: 36),
            orientationButton.heightAnchor.constraint(equalToConstant: 36),

            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: orientationButton.trailingAnchor, constant: 12),
            statusLabelTrailingConstraint,
            statusLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            controlsView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            transportStackLeadingConstraint,
            transportStack.topAnchor.constraint(equalTo: controlsView.topAnchor, constant: 10),

            progressSlider.leadingAnchor.constraint(equalTo: transportStack.trailingAnchor, constant: 8),
            progressSliderTrailingConstraint,
            progressSlider.centerYAnchor.constraint(equalTo: transportStack.centerYAnchor),

            timeLabel.leadingAnchor.constraint(equalTo: transportStack.leadingAnchor),
            timeLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 6),

            systemVolumeView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            systemVolumeView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            systemVolumeView.widthAnchor.constraint(equalToConstant: 1),
            systemVolumeView.heightAnchor.constraint(equalToConstant: 1),

            gestureHUD.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            gestureHUD.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
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
        NSLayoutConstraint.activate(
            isUsingManualLandscape
                ? compactPlaybackControlLayoutConstraints
                : regularPlaybackControlLayoutConstraints
        )
    }

    func configureGestures() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleContentTap))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        contentView.addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = self
        contentView.addGestureRecognizer(panGesture)
    }

    @objc private func handleContentTap() {
        setPlaybackControlsHidden(arePlaybackControlsHidden == false, animated: true)
    }

    func setPlaybackControlsHidden(_ hidden: Bool, animated: Bool) {
        guard arePlaybackControlsHidden != hidden else { return }
        arePlaybackControlsHidden = hidden
        topBar.isUserInteractionEnabled = hidden == false
        controlsView.isUserInteractionEnabled = hidden == false
        topBar.accessibilityElementsHidden = hidden
        controlsView.accessibilityElementsHidden = hidden

        let updates = { [topBar, controlsView] in
            topBar.alpha = hidden ? 0 : 1
            controlsView.alpha = hidden ? 0 : 1
        }
        if animated {
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut],
                animations: updates
            )
        } else {
            updates()
        }
    }

    @objc private func startPictureInPicture() {
        guard player.isPictureInPictureActive == false else {
            player.stopPictureInPicture()
            return
        }
        guard preparePictureInPicturePlayback() else { return }
        player.startPictureInPicture()
    }

    func updatePictureInPictureButton(isActive: Bool) {
        pictureInPictureButton.setImage(
            MPVQuickPlayerSymbol.image(
                isActive ? .pictureInPictureExit : .pictureInPictureEnter,
                pointSize: 17
            ),
            for: .normal
        )
    }

    @discardableResult
    func preparePictureInPicturePlayback(
        activateAudioSession: @MainActor () throws -> Void = MPVQuickPlayerViewController
            .activateMoviePlaybackAudioSession
    ) -> Bool {
        guard player.isPictureInPictureSupported else { return false }
        do {
            try activateAudioSession()
            // PiP is deliberately started only from the explicit control below.
            player.allowsAutomaticPictureInPictureFromInline = false
            return true
        } catch {
            return false
        }
    }

    static func activateMoviePlaybackAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.category != .playback || audioSession.mode != .moviePlayback {
            try audioSession.setCategory(.playback, mode: .moviePlayback)
        }
        try audioSession.setActive(true)
    }

    @objc private func closePlayer() {
        player.stop()
        if isLandscapeForced {
            setForceLandscape(false)
        }
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
