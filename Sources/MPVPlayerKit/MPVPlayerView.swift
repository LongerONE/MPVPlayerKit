import AVFoundation
import QuartzCore
import UIKit
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

@objc public enum MPVPlayerState: Int {
    case buffering
    case readyToPlay
    case bufferFinished
    case paused
    case playedToTheEnd
    case error
}

@objc public enum MPVPlayerDecoderMode: Int {
    case initializing
    case hardware
    case software
}

enum MPVPlayerKitNotification {
    static let didChangeState = Notification.Name("MPVPlayerViewDidChangeState")
    static let didUpdateTime = Notification.Name("MPVPlayerViewDidUpdateTime")
    static let didUpdateBufferingProgress = Notification.Name("MPVPlayerViewDidUpdateBufferingProgress")
    static let didUpdateDecoderMode = Notification.Name("MPVPlayerViewDidUpdateDecoderMode")
    static let didLoadSubtitle = Notification.Name("MPVPlayerViewDidLoadSubtitle")
    static let didCompleteSeek = Notification.Name("MPVPlayerViewDidCompleteSeek")
    static let didChangePictureInPicture = Notification.Name(
        "MPVPlayerViewDidChangePictureInPicture"
    )
}

enum MPVPlayerKitNotificationKey {
    static let state = "state"
    static let currentTime = "currentTime"
    static let duration = "duration"
    static let bufferingProgress = "bufferingProgress"
    static let decoderMode = "decoderMode"
    static let requestID = "requestID"
    static let success = "success"
    static let targetTime = "targetTime"
    static let errorCode = "errorCode"
}

enum MPVProperty {
    static let pause = "pause"
    static let pausedForCache = "paused-for-cache"
    static let timePosition = "time-pos"
    static let duration = "duration"
    static let panscan = "panscan"
    static let speed = "speed"
    static let subtitleVisibility = "sub-visibility"
    static let subtitleID = "sid"
    static let audioID = "aid"
    static let videoID = "vid"
    static let hwdecCurrent = "hwdec-current"
    static let subtitleText = "sub-text"
    static let subtitleDelay = "sub-delay"
    static let subtitleASSOverride = "sub-ass-override"
    static let subtitleFont = "sub-font"
    static let subtitleFontProvider = "sub-font-provider"
    static let subtitleFontSize = "sub-font-size"
    static let subtitleBold = "sub-bold"
    static let subtitleColor = "sub-color"
    static let subtitleOutlineSize = "sub-outline-size"
    static let subtitleOutlineColor = "sub-outline-color"
    static let subtitleBlur = "sub-blur"
    static let subtitleShadowOffset = "sub-shadow-offset"
    static let subtitleBackColor = "sub-back-color"
    static let subtitleBorderStyle = "sub-border-style"
    static let subtitleMarginY = "sub-margin-y"
    static let videoOutputDisplayWidth = "video-out-params/dw"
    static let videoOutputDisplayHeight = "video-out-params/dh"
    static let estimatedVideoFilterFPS = "estimated-vf-fps"
    static let containerFPS = "container-fps"
    static let osdMarginLeft = "osd-dimensions/ml"
    static let osdMarginTop = "osd-dimensions/mt"
    static let osdMarginRight = "osd-dimensions/mr"
    static let osdMarginBottom = "osd-dimensions/mb"
}

enum MPVSubtitleFont {
    static let regular = "NotoSansSC-Regular"
    static let bold = "NotoSansCJKjp-Bold"

    static func name(isBold: Bool) -> String {
        isBold ? bold : regular
    }
}

struct MPVSetupProfile {
    let name: String
    let options: [(String, String)]
}

enum MPVVideoQualityPreset: Int {
    case powerSaving = 0
    case balanced = 1
    case highQuality = 2

    var options: [(String, String)] {
        switch self {
        case .powerSaving:
            return [
                ("scale", "bilinear"),
                ("cscale", "bilinear"),
                ("dscale", "bilinear"),
                ("scaler-resizes-only", "yes"),
                ("scale-antiring", "0.0"),
                ("cscale-antiring", "0.0"),
                ("dscale-antiring", "0.0"),
                ("correct-downscaling", "no"),
                ("linear-downscaling", "no"),
                ("sigmoid-upscaling", "no"),
                ("dither", "no"),
                ("dither-depth", "no"),
                ("hdr-compute-peak", "no"),
                ("allow-delayed-peak-detect", "no"),
                ("interpolation", "no"),
            ]
        case .balanced:
            return [
                ("scale", "lanczos"),
                ("cscale", "bilinear"),
                ("dscale", "mitchell"),
                ("scaler-resizes-only", "yes"),
                ("scale-antiring", "0.0"),
                ("cscale-antiring", "0.0"),
                ("dscale-antiring", "0.0"),
                ("correct-downscaling", "no"),
                ("linear-downscaling", "no"),
                ("sigmoid-upscaling", "no"),
                ("dither", "no"),
                ("dither-depth", "auto"),
                ("hdr-compute-peak", "no"),
                ("allow-delayed-peak-detect", "no"),
                ("interpolation", "no"),
            ]
        case .highQuality:
            return [
                ("scale", "ewa_lanczossharp"),
                ("cscale", "ewa_lanczos"),
                // 4K Dolby Vision is normally downscaled to the phone's
                // display. Keep the high-quality EWA path for upscaling, but
                // use Lanczos for downscaling so the costly path does not
                // consume the frame budget on every frame.
                ("dscale", "lanczos"),
                ("scaler-resizes-only", "yes"),
                ("scale-antiring", "0.6"),
                ("cscale-antiring", "0.6"),
                ("dscale-antiring", "0.0"),
                ("correct-downscaling", "yes"),
                ("linear-downscaling", "no"),
                ("sigmoid-upscaling", "yes"),
                ("dither", "fruit"),
                ("dither-depth", "auto"),
                ("hdr-compute-peak", "yes"),
                ("allow-delayed-peak-detect", "no"),
                ("interpolation", "no"),
            ]
        }
    }
}

enum MPVContentModeSnapshot {
    case fit
    case fill

    init(contentModeRawValue: Int) {
        self = contentModeRawValue == UIView.ContentMode.scaleAspectFill.rawValue ? .fill : .fit
    }
}

@objc(MPVPlayerView)
public final class MPVPlayerView: UIView {
    @objc public internal(set) var isPlaying = false
    @objc public internal(set) var duration: TimeInterval = 0.0
    @objc public internal(set) var currentTime: TimeInterval = 0.0
    public internal(set) var currentSubtitleFontCapability: MPVSubtitleFontCapability = .noSubtitle
    /// Playback speed reported to the system playback controls and to the
    /// Picture in Picture timebase, so both advance at the rate of the video.
    @objc public internal(set) var playbackSpeed: Double = 1.0

    public var playerContentMode: UIView.ContentMode {
        get {
            contentMode
        }
        set {
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self] in
                    self?.playerContentMode = newValue
                }
                return
            }
            contentMode = newValue
            let contentModeSnapshot = MPVContentModeSnapshot(contentModeRawValue: newValue.rawValue)
            setContentModeSnapshot(contentModeSnapshot)
            applyContentMode(contentModeSnapshot)
        }
    }

    @objc public var playerContentModeRawValue: Int {
        get {
            contentMode.rawValue
        }
        set {
            let mode = UIView.ContentMode(rawValue: newValue) ?? .scaleAspectFit
            playerContentMode = mode
        }
    }

    var metalLayer = MPVPlayerMetalLayer()
    var pictureInPictureCoordinator: MPVPictureInPictureCoordinator?
    /// Shapes the Picture in Picture window, which hosts this view.
    var pictureInPictureVideoDisplaySize: CGSize = .zero
    var usesExtendedDynamicRangeOutput = false
    let colorOutputStateLock = NSLock()
    nonisolated(unsafe) var colorOutputState = MPVColorOutputState()
    var url: URL?
    // libmpv setup consumes this immutable request snapshot on `queue`.
    // The host configures it before playback starts, so it must not inherit
    // UIView's main-actor isolation when the queue prepares HTTP headers.
    nonisolated(unsafe) var headers: [String: String] = [:]
    var userAgent: String?
    nonisolated let queue = DispatchQueue(label: "com.mpvplayerkit.player", qos: .userInitiated)
    let queueSpecificKey = DispatchSpecificKey<Void>()
    // Resolve the resource bundle while the UIView is created on the main
    // thread. `setupMPV` runs on `queue`; querying Bundle from there can trip
    // Swift's executor assertion in a Swift package build.
    nonisolated let systemSubtitleFontDirectory: String?
    nonisolated(unsafe) var customSubtitleFontName: String?
    let contentModeSnapshotLock = NSLock()
    var contentModeSnapshot: MPVContentModeSnapshot = .fit
    nonisolated let mediaTracksCacheLock = NSLock()
    nonisolated(unsafe) var mediaTracksCache: [[String: Any]] = []
    nonisolated(unsafe) var mpv: OpaquePointer?
    // Queue-bound cache used when libmpv has already reported shutdown.
    nonisolated(unsafe) var lastMPVTimeSnapshot: MPVPlaybackTimeSnapshot?
    var timeTimer: DispatchSourceTimer?
    var hasReportedReadyToPlay = false
    nonisolated(unsafe) var hasPlaybackRestarted = false
    nonisolated(unsafe) var hasLoggedVideoColorParameters = false
    let playbackStateLock = NSLock()
    nonisolated(unsafe) var stopped = false
    nonisolated(unsafe) var setupFailed = false
    nonisolated(unsafe) var playbackIntentGeneration: UInt64 = 0
    var forceSoftwareDecode = false
    /// Host metadata hint retained for diagnostics. Frame metadata and display
    /// capability, not this value, control color mapping.
    var isDolbyVisionPlayback = false
    nonisolated(unsafe) var currentSubtitleUsesOriginalStyle = false
    // Runtime playback updates are serialized on `queue`, not the UIView's
    // main-actor executor. Keep these snapshots available to those queue-bound
    // helpers; configuration writes happen before the MPV handle is started.
    nonisolated(unsafe) var videoQualityPreset = MPVVideoQualityPreset.balanced
    nonisolated(unsafe) var debandEnabled = false
    nonisolated(unsafe) var subtitleDelayValue = 0.0
    let clientSubtitleController = MPVSubtitlePresentationController()
    nonisolated(unsafe) var subtitleStyleValues: [String: String] = [
        MPVProperty.subtitleFont: MPVSubtitleFont.regular,
        MPVProperty.subtitleFontSize: "38.000",
        MPVProperty.subtitleBold: "no",
        MPVProperty.subtitleColor: "#FFFFFFFF",
        MPVProperty.subtitleOutlineSize: "0.000",
        MPVProperty.subtitleOutlineColor: "#FF000000",
        MPVProperty.subtitleBlur: "0.000",
        MPVProperty.subtitleShadowOffset: "0.000",
        MPVProperty.subtitleBackColor: "#FF000000",
        MPVProperty.subtitleBorderStyle: "outline-and-shadow",
        MPVProperty.subtitleMarginY: "34",
    ]
    struct PendingExternalSubtitleLoad {
        let userdata: UInt64
        let selectionEpoch: UInt64
        let url: String
        let source: String
        let usesOriginalStyle: Bool
        let trackIDsBeforeLoad: Set<Int64>
        let previousSelection: SubtitleSelectionSnapshot
        var requestIDs: [String]
    }

    struct PendingSeek {
        let userdata: UInt64
        let request: MPVSeekRequest
    }

    struct SubtitleSelectionSnapshot {
        let usesOriginalStyle: Bool
        let subtitleID: Int64?
        let isVisible: Bool
    }

    struct ExternalSubtitleActivation {
        let selectionEpoch: UInt64
        let subtitleID: Int64
        let previousSelection: SubtitleSelectionSnapshot
        var requestIDs: Set<String>
    }

    // Access only from `queue`; command reply handling runs on this queue as well.
    nonisolated(unsafe) var loadedExternalSubtitleIDs: [String: Int64] = [:]
    nonisolated(unsafe) var pendingExternalSubtitleLoad: PendingExternalSubtitleLoad?
    nonisolated(unsafe) var canceledExternalSubtitleCommands: [UInt64: PendingExternalSubtitleLoad] = [:]
    nonisolated(unsafe) var pendingSeekCommands: [UInt64: PendingSeek] = [:]
    nonisolated(unsafe) var activeExternalSubtitleActivation: ExternalSubtitleActivation?
    nonisolated(unsafe) var committedSubtitleSelection: SubtitleSelectionSnapshot?
    nonisolated(unsafe) var nextMPVCommandUserdata: UInt64 = 1
    nonisolated(unsafe) var subtitleSelectionEpoch: UInt64 = 0
    nonisolated(unsafe) var lastLoggedSubtitleText = ""
    nonisolated(unsafe) var hasLoggedSubtitleTextEvent = false
    nonisolated(unsafe) var repeatedMPVLogMessageCounts: [String: Int] = [:]
    var lastAppliedLayerBounds = CGRect.null
    var lastAppliedDrawableSize = CGSize.zero
    /// A Picture in Picture hierarchy callback can arrive before UIKit has
    /// assigned the view a size in its destination hierarchy. Keep the
    /// resynchronization pending instead of applying a zero-sized drawable.
    var pendingPictureInPictureGeometryResynchronizationReason: String?
    /// PiP returns the player before the inline hierarchy has always finished
    /// its transition. Keep one bounded retry task so the first stable inline
    /// layout is applied without requiring a device rotation.
    var pictureInPictureGeometryResynchronizationTask: Task<Void, Never>?
    var pictureInPictureGeometryResynchronizationGeneration = 0
    var pendingMetalLayerGeometry: MPVMetalLayerGeometry?
    var isMetalGeometryTransitionInProgress = false
    var geometryTransitionOverlayView: UIView?
    var geometryTransitionPreparedTargetSize = CGSize.zero
    let geometryTransitionFallbackAlpha: CGFloat = 0.58
    let geometryTransitionDimAlpha: CGFloat = 0.36
    let geometryTransitionFadeOutDuration: TimeInterval = 0.32
    var geometryTransitionAnimationID = 0
    nonisolated(unsafe) var setupProfiles: [MPVSetupProfile] = []
    nonisolated(unsafe) var activeSetupProfileIndex = 0
    nonisolated let pictureInPictureRendererRuntimeState =
        MPVPictureInPictureRendererRuntimeState()

    @objc public override init(frame: CGRect) {
        systemSubtitleFontDirectory = Self.resolveSystemSubtitleFontDirectory()
        super.init(frame: frame)
        queue.setSpecific(key: queueSpecificKey, value: ())
        setupLayer()
        clientSubtitleController.install(in: self)
    }

    private static func resolveSystemSubtitleFontDirectory() -> String? {
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle(for: MPVPlayerView.self)
        #endif
        return resourceBundle
            .url(forResource: "NotoSansSC-Regular", withExtension: "otf")?
            .deletingLastPathComponent()
            .path
    }

    public convenience init(url: URL, headers: [String: String], userAgent: String?) {
        self.init(frame: .zero)
        configure([
            "url": url.absoluteString,
            "headers": headers,
            "userAgent": userAgent as Any,
        ])
    }

    func setupLayer() {
        backgroundColor = .black
        metalLayer.framebufferOnly = true
        metalLayer.needsDisplayOnBoundsChange = true
        // A detached view has no target screen. Start conservatively in SDR;
        // didMoveToWindow selects the actual screen before normal playback.
        applyColorOutputMode(.sdr, reason: "initial-detached")
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
    }

    func refreshColorOutputForTargetScreen(reason: String) {
        let desiredMode: MPVColorOutputMode
        #if os(iOS) && !targetEnvironment(simulator)
        if #available(iOS 16.0, *), let targetScreen = window?.windowScene?.screen {
            desiredMode = MPVColorMappingPolicy.supportsExtendedDynamicRange(
                potentialHeadroom: targetScreen.potentialEDRHeadroom
            ) ? .extendedDynamicRange : .sdr
        } else {
            desiredMode = .sdr
        }
        #else
        desiredMode = .sdr
        #endif

        colorOutputStateLock.lock()
        let modeToApply = colorOutputState.request(desiredMode)
        let pendingMode = colorOutputState.pendingMode
        colorOutputStateLock.unlock()

        if let modeToApply {
            applyColorOutputMode(modeToApply, reason: reason)
        } else if pendingMode != nil {
            // Changing CAMetalLayer format invalidates the active Vulkan
            // swapchain. Preserve playback/PiP and consume this persisted mode
            // immediately before the next renderer setup.
            mpvDebugLog("color output change deferred reason=\(reason) renderer-active")
        }
    }

    /// Called from the MPV queue before profiles or handles are created. All
    /// CAMetalLayer mutation is synchronously transferred to the main actor so
    /// the selected options and swapchain format are from the same state.
    nonisolated func prepareColorOutputForRendererSetup() {
        let prepare = { @MainActor [self] in
            colorOutputStateLock.lock()
            let modeToApply = colorOutputState.prepareForRendererSetup()
            colorOutputStateLock.unlock()
            if let modeToApply {
                applyColorOutputMode(modeToApply, reason: "renderer-setup")
            }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(prepare)
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated(prepare)
            }
        }
    }

    nonisolated func markColorOutputRendererStopped() {
        colorOutputStateLock.lock()
        colorOutputState.rendererDidStop()
        colorOutputStateLock.unlock()
    }

    private func applyColorOutputMode(_ outputMode: MPVColorOutputMode, reason: String) {
        usesExtendedDynamicRangeOutput = outputMode == .extendedDynamicRange
        switch outputMode {
        case .sdr:
            metalLayer.pixelFormat = .bgra8Unorm_srgb
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        case .extendedDynamicRange:
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        }
        if #available(iOS 16.0, *) {
            metalLayer.wantsExtendedDynamicRangeContent = usesExtendedDynamicRangeOutput
        }
        let outputDescription = usesExtendedDynamicRangeOutput ? "EDR-scRGB" : "SDR-sRGB"
        mpvDebugLog("color output configured reason=\(reason) pixelFormat=\(metalLayer.pixelFormat.rawValue) output=\(outputDescription)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stop()
    }

    @objc public func configure(_ configuration: NSDictionary) {
        if mpv != nil {
            stop()
        }

        let urlString = configuration["url"] as? String
        url = urlString.flatMap(URL.init(string:))
        headers = configuration["headers"] as? [String: String] ?? [:]
        userAgent = configuration["userAgent"] as? String
        forceSoftwareDecode = boolValue(configuration["forceSoftwareDecode"])
        isDolbyVisionPlayback = boolValue(configuration["isDolbyVisionPlayback"])
        let qualityRawValue = (configuration["videoQuality"] as? NSNumber)?.intValue
        videoQualityPreset = qualityRawValue.flatMap(MPVVideoQualityPreset.init(rawValue:)) ?? .balanced
        debandEnabled = boolValue(configuration["debandEnabled"])
        setDecoderMode(.initializing)
        setStopped(false)
        setSetupFailed(false)
        hasReportedReadyToPlay = false
        resetPictureInPictureVideoDisplaySize()
        hasPlaybackRestarted = false
        hasLoggedVideoColorParameters = false
        setupProfiles = []
        activeSetupProfileIndex = 0
        pictureInPictureRendererRuntimeState.reset()
        lastAppliedLayerBounds = CGRect.null
        lastAppliedDrawableSize = .zero
        pictureInPictureGeometryResynchronizationTask?.cancel()
        pictureInPictureGeometryResynchronizationTask = nil
        pictureInPictureGeometryResynchronizationGeneration &+= 1
        pendingPictureInPictureGeometryResynchronizationReason = nil
        pendingMetalLayerGeometry = nil
        isMetalGeometryTransitionInProgress = false
        geometryTransitionPreparedTargetSize = .zero
        resetGeometryTransitionAnimation()
        currentTime = 0.0
        duration = 0.0
        isPlaying = false
        currentSubtitleFontCapability = .noSubtitle
        playbackSpeed = 1.0
        let colorHint = MPVColorMappingPolicy.contentHint(
            isDolbyVisionPlayback: isDolbyVisionPlayback
        )
        mpvDebugLog("configure url=\(redactedURLDescription(url)) headers=\(headers.count) hasUserAgent=\(userAgent?.isEmpty == false) forceSoftwareDecode=\(forceSoftwareDecode) contentColorHint=\(colorHint.rawValue)")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        clientSubtitleController.update(at: currentTime, force: true)
        if let reason = pendingPictureInPictureGeometryResynchronizationReason {
            resynchronizeMetalLayerGeometry(reason: reason)
            return
        }
        updateMetalLayerGeometryIfNeeded()
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        pictureInPictureViewHierarchyDidChange()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshColorOutputForTargetScreen(reason: "did-move-to-window")
        pictureInPictureViewHierarchyDidChange()
    }

}
