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
    public static let zoom = Self(rawValue: 1 << 3)
    public static let all: Self = [.seeking, .brightness, .volume, .zoom]
}

/// A ready-to-present UIKit player. Apps with their own controls can use `MPVPlayer` directly.
public final class MPVQuickPlayerViewController: UIViewController {
    public let player: MPVPlayer
    public var autoplay: Bool
    public var gestureOptions: MPVQuickPlayerGestureOptions = .all
    public internal(set) var isLandscapeForced: Bool
    /// Orientation policy for resizable displays (iPhone Duo). Default keeps the optional force-landscape control.
    public var orientationPolicy: MPVOrientationPolicy = .optionalForceLandscape {
        didSet { applyOrientationPolicy() }
    }
    /// Extra chrome insets beyond safe area (e.g. system vertical bar channel).
    public private(set) var additionalChromeInsets: MPVPlayerChromeInsets = .zero
    /// Compact chrome when iPhone Duo hinge is partially folded.
    var isHingeCompact = false
    /// iOS 27.1 的真实铰链观察；旧系统不安装。
    var hingeInteraction: AnyObject?
    public internal(set) var playbackRate = 1.0
    public internal(set) var videoQuality: MPVVideoQuality
    public internal(set) var debandEnabled: Bool
    /// The quick player's app-local global cache preference.
    public internal(set) var cacheConfiguration: MPVCacheConfiguration
    public internal(set) var subtitleDelay: TimeInterval = 0
    public internal(set) var subtitleStyle = MPVSubtitleStyle.defaultStyle

    public var diagnosticSessionID: UUID? { player.diagnosticSessionID }
    public func diagnosticLogFiles() async throws -> [URL] {
        try await player.diagnosticLogFiles()
    }

    public var currentSubtitleFontCapability: MPVSubtitleFontCapability {
        player.currentSubtitleFontCapability
    }

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
    var pinchStartScale: Double = 1.0
    var playbackState = MPVPlaybackState.paused
    var idleTimerDisabledBeforePlayback: Bool?
    var decoderMode = MPVDecoderMode.initializing
    var bufferingProgress = 0
    var isDisplayTransitionInProgress = false
    var pendingSubtitleRequestID: UUID?
    var isCancellingSubtitleLoad = false
    var isUsingManualLandscape: Bool
    weak var orientationSynchronizedPresentedViewController: UIViewController?
    weak var actionSheetOverlay: MPVQuickPlayerMenuView?
    weak var settingsPanelOverlay: (UIView & MPVQuickPlayerPanelOverlay)?
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
    var duoMediaConstraints = [NSLayoutConstraint]()
    var duoTopBarConstraints = [NSLayoutConstraint]()
    var duoControlsConstraints = [NSLayoutConstraint]()

    enum PanDirection {
        case none
        case seeking
        case brightness
        case volume
    }

    /// 初始化时**始终**用 `MPVCachePreferences.configuration`（UserDefaults：
    /// `mpv_cache_enabled` / `mpv_cache_duration`）覆盖传入配置中的
    /// `cacheConfiguration`。直接使用 `MPVPlayer` 的宿主不受此覆盖影响。
    /// 用户在缓存面板中的修改会写回 UserDefaults。
    public init(
        configuration: MPVPlayerConfiguration,
        autoplay: Bool = true,
        forceLandscape: Bool = false
    ) {
        let savedCacheConfiguration = MPVCachePreferences.configuration
        var effectiveConfiguration = configuration
        effectiveConfiguration.cacheConfiguration = savedCacheConfiguration
        player = MPVPlayer(configuration: effectiveConfiguration)
        self.autoplay = autoplay
        isLandscapeForced = forceLandscape
        isUsingManualLandscape = forceLandscape && Self.applicationSupportsLandscape == false
        videoQuality = configuration.videoQuality
        debandEnabled = configuration.debandEnabled
        cacheConfiguration = savedCacheConfiguration
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

    public func setSubtitleFont(from url: URL) throws {
        try player.setSubtitleFont(from: url)
    }

    /// Injects host-side chrome padding (safe-area side channel) into playback controls.
    public func setAdditionalChromeInsets(_ insets: MPVPlayerChromeInsets) {
        additionalChromeInsets = insets
        guard isViewLoaded else { return }
        updatePlaybackControlSafeAreaInsets()
        actionSheetOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
        settingsPanelOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
    }

    public func resetSubtitleFont() {
        player.resetSubtitleFont()
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
        applyOrientationPolicy()
        installDuoHingeObservationIfNeeded()
        updatePlaybackControlSafeAreaInsets()
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
        updateOrientationButtonVisibility()
        actionSheetOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
        settingsPanelOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
    }

    public override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updatePlaybackControlSafeAreaInsets()
        actionSheetOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
        settingsPanelOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
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
        player.videoDisplayMode = .fit
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


    func configureGestures() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleContentTap))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        contentView.addGestureRecognizer(tapGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        panGesture.maximumNumberOfTouches = 1
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = self
        contentView.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinchGesture(_:)))
        pinchGesture.cancelsTouchesInView = false
        pinchGesture.delegate = self
        contentView.addGestureRecognizer(pinchGesture)
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

}
