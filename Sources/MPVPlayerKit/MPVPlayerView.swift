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

@objc public enum MPVPlayerState: Int, Sendable {
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
    /// `videotoolbox-copy`：仍是硬解，但帧会拷贝到 CPU 可访问内存。
    case hardwareCopy

    /// 与 `MPVDecoderMode.init(hardwareDecodeCurrent:)` 同一语义。
    init(hardwareDecodeCurrent value: String?) {
        switch MPVDecoderMode(hardwareDecodeCurrent: value) {
        case .initializing: self = .initializing
        case .hardware: self = .hardware
        case .software: self = .software
        case .hardwareCopy: self = .hardwareCopy
        }
    }
}

/// 公共通知名与 payload key。字符串与现网一致，供宿主（含 Temby 桥接）直接引用。
public enum MPVPlayerKitNotification {
    public static let didChangeState = Notification.Name("MPVPlayerViewDidChangeState")
    public static let didUpdateTime = Notification.Name("MPVPlayerViewDidUpdateTime")
    public static let didUpdateBufferingProgress = Notification.Name("MPVPlayerViewDidUpdateBufferingProgress")
    public static let didUpdateBufferedProgress = Notification.Name("MPVPlayerViewDidUpdateBufferedProgress")
    public static let didUpdateDecoderMode = Notification.Name("MPVPlayerViewDidUpdateDecoderMode")
    public static let didLoadSubtitle = Notification.Name("MPVPlayerViewDidLoadSubtitle")
    public static let didCompleteSeek = Notification.Name("MPVPlayerViewDidCompleteSeek")
    public static let didChangePictureInPicture = Notification.Name(
        "MPVPlayerViewDidChangePictureInPicture"
    )
}

public enum MPVPlayerKitNotificationKey {
    public static let state = "state"
    public static let currentTime = "currentTime"
    public static let duration = "duration"
    public static let bufferingProgress = "bufferingProgress"
    public static let bufferedProgress = "bufferedProgress"
    public static let decoderMode = "decoderMode"
    public static let requestID = "requestID"
    public static let success = "success"
    public static let targetTime = "targetTime"
    public static let errorCode = "errorCode"
}

enum MPVProperty {
    static let pause = "pause"
    static let cache = "cache"
    static let cacheSeconds = "cache-secs"
    static let pausedForCache = "paused-for-cache"
    static let cacheBufferingState = "cache-buffering-state"
    static let coreIdle = "core-idle"
    static let idleActive = "idle-active"
    static let eofReached = "eof-reached"
    static let seeking = "seeking"
    static let demuxerCacheState = "demuxer-cache-state"
    static let demuxerCacheTime = "demuxer-cache-time"
    static let trackListCount = "track-list/count"
    static let timePosition = "time-pos"
    static let duration = "duration"
    static let panscan = "panscan"
    static let videoZoom = "video-zoom"
    static let speed = "speed"
    static let subtitleVisibility = "sub-visibility"
    static let subtitleID = "sid"
    static let audioID = "aid"
    static let videoID = "vid"
    static let hwdecCurrent = "hwdec-current"
    static let subtitleText = "sub-text"
    static let subtitleDelay = "sub-delay"
    static let subtitleASSOverride = "sub-ass-override"
    static let subtitleScale = "sub-scale"
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
    static let videoDisplayWidth = "dwidth"
    static let videoDisplayHeight = "dheight"
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
                // Keep adaptive HDR tone mapping enabled in the low-cost
                // tiers. Disabling peak detection can make HDR output
                // unstable on some device/render-target combinations.
                ("hdr-compute-peak", "auto"),
                // Permit mpv to avoid an extra FBO in the simple low-cost path.
                ("allow-delayed-peak-detect", "yes"),
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
                ("hdr-compute-peak", "auto"),
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

@objc(MPVPlayerView)
public final class MPVPlayerView: UIView {
    @objc public internal(set) var isPlaying = false
    @objc public internal(set) var duration: TimeInterval = 0.0
    @objc public internal(set) var currentTime: TimeInterval = 0.0
    @objc public internal(set) var bufferedProgress: NSNumber?
    public internal(set) var currentSubtitleFontCapability: MPVSubtitleFontCapability = .noSubtitle
    /// Playback speed reported to the system playback controls and to the
    /// Picture in Picture timebase, so both advance at the rate of the video.
    @objc public internal(set) var playbackSpeed: Double = 1.0

    /// Hosts with their own remote command coordinator can disable MPV's
    /// built-in system playback controls to avoid duplicate command handlers.
    /// `false→true` 且当前正在播放时会重新 activate；`true→false` 会 deactivate。
    @objc public var systemPlaybackControlsEnabled = true {
        didSet {
            guard oldValue != systemPlaybackControlsEnabled else { return }
            if systemPlaybackControlsEnabled == false {
                MPVSystemPlaybackCoordinator.shared.deactivate(playerView: self)
            } else if isPlaying {
                MPVSystemPlaybackCoordinator.shared.activate(
                    playerView: self,
                    isTimeAdvancing: true
                )
            }
        }
    }

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
            videoDisplayMode = newValue == .scaleAspectFill ? .fill : .fit
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

    nonisolated(unsafe) var metalLayer = MPVPlayerMetalLayer()
#if targetEnvironment(simulator)
    nonisolated(unsafe) var softwareVideoLayer = CALayer(); nonisolated(unsafe) var softwareRenderer: MPVSoftwareRenderer?
#endif
    var pictureInPictureCoordinator: MPVPictureInPictureCoordinator?
    /// Shapes the Picture in Picture window, which hosts this view.
    var pictureInPictureVideoDisplaySize: CGSize = .zero
    var usesExtendedDynamicRangeOutput = false
    let colorOutputStateLock = NSLock()
    nonisolated(unsafe) var colorOutputState = MPVColorOutputState()
    nonisolated(unsafe) var url: URL?
    // libmpv setup consumes this immutable request snapshot on `queue`.
    // The host configures it before playback starts, so it must not inherit
    // UIView's main-actor isolation when the queue prepares HTTP headers.
    nonisolated(unsafe) var headers: [String: String] = [:]
    nonisolated let queue = DispatchQueue(label: "com.mpvplayerkit.player", qos: .userInitiated)
    let queueSpecificKey = DispatchSpecificKey<Void>()
    // Resolve the resource bundle while the UIView is created on the main
    // thread. `setupMPV` runs on `queue`; querying Bundle from there can trip
    // Swift's executor assertion in a Swift package build.
    nonisolated let systemSubtitleFontDirectory: String?
    nonisolated(unsafe) var customSubtitleFontName: String?
    let contentModeSnapshotLock = NSLock()
    var contentModeSnapshot: MPVContentModeSnapshot = .fit
    var displayModeState = MPVDisplayModeState()
    nonisolated let mediaTracksCacheLock = NSLock()
    nonisolated(unsafe) var mediaTracksCache: [[String: Any]] = []
    nonisolated let subtitleTextCacheLock = NSLock()
    nonisolated(unsafe) var cachedSubtitleText: String?
    nonisolated(unsafe) var mpv: OpaquePointer?
    // mpv 句柄与 wakeup 上下文的取出/置空需互斥，避免 stop 与 deinit 并发销毁。
    let mpvHandleLock = NSLock()
    // Bound to the MPV handle on `queue`. Playback snapshots carry this value
    // so a queued callback from a previous handle cannot inherit a newer
    // main-thread buffering session while teardown is still pending.
    nonisolated(unsafe) var mpvPlaybackUpdateSourceSessionGeneration: UInt64?
    // diagnosticProbe 与 mpv 一样只在 MPV 串行队列访问。
    nonisolated(unsafe) var diagnosticProbe: MPVDiagnosticProbe?
    // wakeup 回调 userdata：retain 到 handle 销毁，避免 passUnretained UAF。
    nonisolated(unsafe) var wakeupContextTransfer: Unmanaged<MPVWakeupContext>?
    var diagnosticMonitor: MPVDiagnosticMonitor?
    @objc public internal(set) var diagnosticSessionID: UUID?
    // Queue-bound cache used when libmpv has already reported shutdown.
    nonisolated(unsafe) var lastMPVTimeSnapshot: MPVPlaybackTimeSnapshot?
    /// MPV 队列：未就绪时早期探针节流时间戳。
    nonisolated(unsafe) var lastEarlyProbeUptime: TimeInterval = 0
    /// mediaTracks 空轨轮询日志节流（requestedType|count）。
    nonisolated(unsafe) var lastMediaTracksLogSignature: String?
    // 仅在 MPV 串行队列上创建/取消；主线程只提交启停意图。
    nonisolated(unsafe) var timeTimer: DispatchSourceTimer?
    // Ready 上报与 profile 回退可跨主线程/MPV 队列读写，统一走 playbackStateLock。
    nonisolated(unsafe) var hasReportedReadyToPlay = false
    nonisolated(unsafe) var hasPlaybackRestarted = false
    let playbackStateLock = NSLock()
    nonisolated(unsafe) var stopped = false
    nonisolated(unsafe) var setupFailed = false
    nonisolated(unsafe) var playbackIntentGeneration: UInt64 = 0
    nonisolated(unsafe) var playbackPositionGeneration: UInt64 = 0
    nonisolated(unsafe) var pendingPlaybackPositionGeneration: UInt64?
    // 配置快照字段：主线程 configure 写入，MPV 队列 setup 读取。
    nonisolated(unsafe) var forceSoftwareDecode = false
    /// Host metadata hint retained for diagnostics. Frame metadata and display
    /// capability, not this value, control color mapping.
    nonisolated(unsafe) var isDolbyVisionPlayback = false
    nonisolated(unsafe) var userAgent: String?
    nonisolated(unsafe) var currentSubtitleUsesOriginalStyle = false
    // Runtime playback updates are serialized on `queue`, not the UIView's
    // main-actor executor. Keep these snapshots available to those queue-bound
    // helpers; configuration writes happen before the MPV handle is started.
    nonisolated(unsafe) var videoQualityPreset = MPVVideoQualityPreset.balanced
    nonisolated(unsafe) var debandEnabled = false
    nonisolated(unsafe) var cacheConfiguration = MPVCacheConfiguration.default
    // Buffering state is reduced on the MPV queue. The work item is kept
    // queue-bound as well, so an obsolete core-idle fallback cannot publish
    // after a new playback intent or handle teardown.
    nonisolated(unsafe) var bufferingStateMachine = MPVBufferingStateMachine()
    nonisolated(unsafe) var bufferingFallbackWorkItem: DispatchWorkItem?
    nonisolated(unsafe) var bufferingFallbackGeneration: UInt64 = 0
    // Guarded by playbackStateLock because configure runs on MainActor while
    // teardown and buffering decisions run on the MPV queue.
    nonisolated(unsafe) var bufferingSessionGeneration: UInt64 = 0
    nonisolated(unsafe) var bufferingActiveSeekCount = 0
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
    /// The renderer surface is allocated once for the playback session. UIKit
    /// rotation only changes the presentation mapping applied to this surface.
    var stableMetalCanvas: MPVStableMetalCanvas?
    nonisolated(unsafe) var videoDisplayAspectRatio = MPVDisplayGeometry.defaultVideoAspectRatio
    let videoDisplayAspectRatioLock = NSLock()
    /// A Picture in Picture hierarchy callback can arrive before UIKit has
    /// assigned the view a size in its destination hierarchy. Keep the
    /// resynchronization pending instead of applying a zero-sized drawable.
    var pendingPictureInPictureGeometryResynchronizationReason: String?
    /// PiP returns the player before the inline hierarchy has always finished
    /// its transition. Keep one bounded retry task so the first stable inline
    /// layout is applied without requiring a device rotation.
    var pictureInPictureGeometryResynchronizationTask: Task<Void, Never>?
    var pictureInPictureGeometryResynchronizationGeneration = 0
    nonisolated(unsafe) var setupProfiles: [MPVSetupProfile] = []
    nonisolated(unsafe) var activeSetupProfileIndex = 0; nonisolated(unsafe) var pendingProfileRetry: (resumeTime: TimeInterval, shouldPlay: Bool)?
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
        clipsToBounds = true
        metalLayer.framebufferOnly = true
        metalLayer.needsDisplayOnBoundsChange = true
        // A detached view has no target screen. Start conservatively in SDR;
        // didMoveToWindow selects the actual screen before normal playback.
        applyColorOutputMode(.sdr, reason: "initial-detached")
        metalLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(metalLayer)
#if targetEnvironment(simulator)
        metalLayer.isHidden = true
        softwareVideoLayer.contentsGravity = .resizeAspect
        layer.addSublayer(softwareVideoLayer)
#endif
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
        // deinit 不得经 stop() → queue.async { [self] } 复活对象。
        _ = detachHandleForDeinitTeardown()
    }

    @objc public func configure(_ configuration: NSDictionary) {
        // 不在主线程读取 mpv 指针；stop 自身带 generation/stopped 守卫。
        stop()

        let urlString = configuration["url"] as? String
        url = urlString.flatMap(URL.init(string:))
        headers = configuration["headers"] as? [String: String] ?? [:]
        userAgent = configuration["userAgent"] as? String
        forceSoftwareDecode = boolValue(configuration["forceSoftwareDecode"])
        isDolbyVisionPlayback = boolValue(configuration["isDolbyVisionPlayback"])
        let qualityRawValue = (configuration["videoQuality"] as? NSNumber)?.intValue
        videoQualityPreset = qualityRawValue.flatMap(MPVVideoQualityPreset.init(rawValue:)) ?? .balanced
        debandEnabled = boolValue(configuration["debandEnabled"])
        cacheConfiguration = MPVCacheConfiguration(
            isEnabled: boolValue(configuration["cacheEnabled"], default: true),
            duration: (configuration["cacheDuration"] as? NSNumber)?.doubleValue ?? MPVCacheConfiguration.defaultDuration
        )
        configurePowerDiagnostics(configuration)
        setDecoderMode(.initializing)
        setStopped(false)
        setSetupFailed(false)
        setReadyToPlayReported(false)
        resetPictureInPictureVideoDisplaySize()
        setPlaybackRestarted(false)
        replaceSetupProfiles([], activeIndex: 0)
        pictureInPictureRendererRuntimeState.reset()
        stableMetalCanvas = nil
        videoDisplayAspectRatioLock.lock()
        videoDisplayAspectRatio = MPVDisplayGeometry.defaultVideoAspectRatio
        videoDisplayAspectRatioLock.unlock()
        pictureInPictureGeometryResynchronizationTask?.cancel()
        pictureInPictureGeometryResynchronizationTask = nil
        pictureInPictureGeometryResynchronizationGeneration &+= 1
        pendingPictureInPictureGeometryResynchronizationReason = nil
        currentTime = 0.0
        duration = 0.0
        bufferedProgress = nil
        isPlaying = false
        currentSubtitleFontCapability = .noSubtitle
        playbackSpeed = 1.0
        _ = nextPlaybackIntentGeneration()
        clearPendingPlaybackPositionUpdate()
        _ = nextBufferingSessionGeneration()
        queue.async { [weak self] in
            self?.resetBufferingStateOnMPVQueue(reason: "configure")
        }
        let colorHint = MPVColorMappingPolicy.contentHint(
            isDolbyVisionPlayback: isDolbyVisionPlayback
        )
        mpvDebugLog("configure url=\(redactedURLDescription(url)) headers=\(headers.count) hasUserAgent=\(userAgent?.isEmpty == false) forceSoftwareDecode=\(forceSoftwareDecode) contentColorHint=\(colorHint.rawValue)")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        #if targetEnvironment(simulator)
        if bounds.width > 1, bounds.height > 1 {
            softwareVideoLayer.frame = bounds
            applySoftwareVideoGravity()
        }
        #endif
        clientSubtitleController.update(at: currentTime, force: true)
        if let reason = pendingPictureInPictureGeometryResynchronizationReason {
            resynchronizeMetalLayerGeometry(reason: reason)
            return
        }
        updateDisplayPresentationMapping(reason: "layout")
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
