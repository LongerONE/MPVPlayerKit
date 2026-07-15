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
}

enum MPVPlayerKitNotificationKey {
    static let state = "state"
    static let currentTime = "currentTime"
    static let duration = "duration"
    static let bufferingProgress = "bufferingProgress"
    static let decoderMode = "decoderMode"
    static let requestID = "requestID"
    static let success = "success"
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
    static let subtitleShadowOffset = "sub-shadow-offset"
    static let subtitleBackColor = "sub-back-color"
    static let subtitleBorderStyle = "sub-border-style"
    static let subtitleMarginY = "sub-margin-y"
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
                ("correct-downscaling", "no"),
                ("sigmoid-upscaling", "no"),
            ]
        case .balanced:
            return [
                ("scale", "lanczos"),
                ("cscale", "bilinear"),
                ("dscale", "hermite"),
                ("correct-downscaling", "yes"),
                ("sigmoid-upscaling", "yes"),
            ]
        case .highQuality:
            return [
                ("scale", "ewa_lanczossharp"),
                ("cscale", "ewa_lanczos"),
                ("dscale", "mitchell"),
                ("correct-downscaling", "yes"),
                ("sigmoid-upscaling", "yes"),
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
    static let sharedMetalVideoOutputOptions: [(String, String)] = [
        ("vo", "gpu-next"),
        ("gpu-api", "vulkan"),
        ("gpu-context", "moltenvk"),
        ("blend-subtitles", "video"),
        ("gpu-shader-cache", "yes"),
        ("tone-mapping", "bt.2446a"),
        ("hdr-compute-peak", "auto"),
        ("allow-delayed-peak-detect", "yes"),
        ("gamut-mapping-mode", "auto"),
        ("demuxer-hysteresis-secs", "10"),
    ]

    static let edrMetalVideoOutputOptions = sharedMetalVideoOutputOptions + [
        ("fbo-format", "rgba16f"),
        ("target-colorspace-hint", "yes"),
        ("target-colorspace-hint-mode", "source"),
    ]

    static let dolbyVisionEDRMetalVideoOutputOptions = sharedMetalVideoOutputOptions + [
        ("fbo-format", "rgba16f"),
        ("target-colorspace-hint", "yes"),
        ("target-colorspace-hint-mode", "source-dynamic"),
    ]

    static let sdrMetalVideoOutputOptions = sharedMetalVideoOutputOptions + [
        ("target-trc", "srgb"),
        ("target-prim", "bt.709"),
    ]

    @objc public internal(set) var isPlaying = false
    @objc public internal(set) var duration: TimeInterval = 0.0
    @objc public internal(set) var currentTime: TimeInterval = 0.0

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
    var usesExtendedDynamicRangeOutput = false
    var url: URL?
    var headers: [String: String] = [:]
    var userAgent: String?
    let queue = DispatchQueue(label: "com.mpvplayerkit.player", qos: .userInitiated)
    let queueSpecificKey = DispatchSpecificKey<Void>()
    let contentModeSnapshotLock = NSLock()
    var contentModeSnapshot: MPVContentModeSnapshot = .fit
    var mpv: OpaquePointer?
    var timeTimer: DispatchSourceTimer?
    var hasReportedReadyToPlay = false
    var hasPlaybackRestarted = false
    var hasLoggedVideoColorParameters = false
    var stopped = false
    var setupFailed = false
    var forceSoftwareDecode = false
    var isDolbyVisionPlayback = false
    var currentSubtitleUsesOriginalStyle = false
    var videoQualityPreset = MPVVideoQualityPreset.balanced
    var debandEnabled = false
    var interpolationOptions = MPVInterpolationOptions.off
    var subtitleDelayValue = 0.0
    var subtitleStyleValues: [String: String] = [
        MPVProperty.subtitleFontSize: "38.000",
        MPVProperty.subtitleBold: "no",
        MPVProperty.subtitleColor: "#FFFFFFFF",
        MPVProperty.subtitleOutlineSize: "0.000",
        MPVProperty.subtitleOutlineColor: "#FF000000",
        MPVProperty.subtitleShadowOffset: "0.000",
        MPVProperty.subtitleBackColor: "#00000000",
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
    var loadedExternalSubtitleIDs: [String: Int64] = [:]
    var pendingExternalSubtitleLoad: PendingExternalSubtitleLoad?
    var canceledExternalSubtitleCommands: [UInt64: PendingExternalSubtitleLoad] = [:]
    var activeExternalSubtitleActivation: ExternalSubtitleActivation?
    var committedSubtitleSelection: SubtitleSelectionSnapshot?
    var nextSubtitleLoadUserdata: UInt64 = 1
    var subtitleSelectionEpoch: UInt64 = 0
    var lastLoggedSubtitleText = ""
    var hasLoggedSubtitleTextEvent = false
    var repeatedMPVLogMessageCounts: [String: Int] = [:]
    var lastAppliedLayerBounds = CGRect.null
    var lastAppliedDrawableSize = CGSize.zero
    var videoOutputRefreshWorkItem: DispatchWorkItem?
    var geometryTransitionOverlayView: UIView?
    var geometryTransitionPreparedTargetSize = CGSize.zero
    let geometryTransitionFallbackAlpha: CGFloat = 0.58
    let geometryTransitionDimAlpha: CGFloat = 0.36
    let geometryTransitionFadeOutDuration: TimeInterval = 0.32
    var geometryTransitionAnimationID = 0
    var setupProfiles: [MPVSetupProfile] = []
    var activeSetupProfileIndex = 0

    @objc public override init(frame: CGRect) {
        super.init(frame: frame)
        queue.setSpecific(key: queueSpecificKey, value: ())
        setupLayer()
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
        #if os(iOS)
        if #available(iOS 16.0, *) {
            usesExtendedDynamicRangeOutput = true
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            metalLayer.wantsExtendedDynamicRangeContent = true
        } else {
            usesExtendedDynamicRangeOutput = false
            metalLayer.pixelFormat = .bgra8Unorm_srgb
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
        #else
        usesExtendedDynamicRangeOutput = false
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #endif
        metalLayer.backgroundColor = UIColor.black.cgColor
        let outputDescription = usesExtendedDynamicRangeOutput ? "EDR-scRGB" : "SDR-sRGB"
        mpvDebugLog("setupLayer metal pixelFormat=\(metalLayer.pixelFormat.rawValue) output=\(outputDescription)")
        layer.addSublayer(metalLayer)
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
        interpolationOptions = MPVInterpolationOptions(bridgeDictionary: configuration)
        setDecoderMode(.initializing)
        stopped = false
        setupFailed = false
        hasReportedReadyToPlay = false
        hasPlaybackRestarted = false
        hasLoggedVideoColorParameters = false
        setupProfiles = []
        activeSetupProfileIndex = 0
        lastAppliedLayerBounds = CGRect.null
        lastAppliedDrawableSize = .zero
        videoOutputRefreshWorkItem?.cancel()
        videoOutputRefreshWorkItem = nil
        geometryTransitionPreparedTargetSize = .zero
        resetGeometryTransitionAnimation()
        currentTime = 0.0
        duration = 0.0
        isPlaying = false
        mpvDebugLog("configure url=\(redactedURLDescription(url)) headers=\(headers.count) hasUserAgent=\(userAgent?.isEmpty == false) forceSoftwareDecode=\(forceSoftwareDecode)")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateMetalLayerGeometryIfNeeded()
    }

}

final class MPVPlayerMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get {
            super.drawableSize
        }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}
