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
    static let videoOutputDisplayWidth = "video-out-params/dw"
    static let videoOutputDisplayHeight = "video-out-params/dh"
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
    var pictureInPictureCoordinator: MPVPictureInPictureCoordinator?
    var pictureInPictureVideoDisplaySize: CGSize = .zero
    var usesExtendedDynamicRangeOutput = false
    var url: URL?
    var headers: [String: String] = [:]
    var userAgent: String?
    nonisolated let queue = DispatchQueue(label: "com.mpvplayerkit.player", qos: .userInitiated)
    let queueSpecificKey = DispatchSpecificKey<Void>()
    let contentModeSnapshotLock = NSLock()
    var contentModeSnapshot: MPVContentModeSnapshot = .fit
    nonisolated let mediaTracksCacheLock = NSLock()
    nonisolated(unsafe) var mediaTracksCache: [[String: Any]] = []
    nonisolated(unsafe) var mpv: OpaquePointer?
    var timeTimer: DispatchSourceTimer?
    var hasReportedReadyToPlay = false
    nonisolated(unsafe) var hasPlaybackRestarted = false
    nonisolated(unsafe) var hasLoggedVideoColorParameters = false
    var stopped = false
    var setupFailed = false
    var forceSoftwareDecode = false
    var isDolbyVisionPlayback = false
    nonisolated(unsafe) var currentSubtitleUsesOriginalStyle = false
    // Runtime playback updates are serialized on `queue`, not the UIView's
    // main-actor executor. Keep these snapshots available to those queue-bound
    // helpers; configuration writes happen before the MPV handle is started.
    nonisolated(unsafe) var videoQualityPreset = MPVVideoQualityPreset.balanced
    nonisolated(unsafe) var debandEnabled = false
    nonisolated(unsafe) var interpolationOptions = MPVInterpolationOptions.off
    nonisolated(unsafe) var subtitleDelayValue = 0.0
    let clientSubtitleController = MPVSubtitlePresentationController()
    nonisolated(unsafe) var subtitleStyleValues: [String: String] = [
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
    nonisolated(unsafe) var loadedExternalSubtitleIDs: [String: Int64] = [:]
    nonisolated(unsafe) var pendingExternalSubtitleLoad: PendingExternalSubtitleLoad?
    nonisolated(unsafe) var canceledExternalSubtitleCommands: [UInt64: PendingExternalSubtitleLoad] = [:]
    nonisolated(unsafe) var activeExternalSubtitleActivation: ExternalSubtitleActivation?
    nonisolated(unsafe) var committedSubtitleSelection: SubtitleSelectionSnapshot?
    nonisolated(unsafe) var nextSubtitleLoadUserdata: UInt64 = 1
    nonisolated(unsafe) var subtitleSelectionEpoch: UInt64 = 0
    nonisolated(unsafe) var lastLoggedSubtitleText = ""
    nonisolated(unsafe) var hasLoggedSubtitleTextEvent = false
    nonisolated(unsafe) var repeatedMPVLogMessageCounts: [String: Int] = [:]
    var lastAppliedLayerBounds = CGRect.null
    var lastAppliedDrawableSize = CGSize.zero
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

    @objc public override init(frame: CGRect) {
        super.init(frame: frame)
        queue.setSpecific(key: queueSpecificKey, value: ())
        setupLayer()
        clientSubtitleController.install(in: self)
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
        #if targetEnvironment(simulator)
        // The simulator Metal driver has much tighter shared-memory limits than
        // real devices. SDR output also matches the compatibility GPU renderer
        // used by the simulator setup profile.
        usesExtendedDynamicRangeOutput = false
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        #else
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
        #endif
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
        pendingMetalLayerGeometry = nil
        isMetalGeometryTransitionInProgress = false
        geometryTransitionPreparedTargetSize = .zero
        resetGeometryTransitionAnimation()
        currentTime = 0.0
        duration = 0.0
        isPlaying = false
        mpvDebugLog("configure url=\(redactedURLDescription(url)) headers=\(headers.count) hasUserAgent=\(userAgent?.isEmpty == false) forceSoftwareDecode=\(forceSoftwareDecode)")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        clientSubtitleController.update(at: currentTime, force: true)
        updateMetalLayerGeometryIfNeeded()
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        pictureInPictureViewHierarchyDidChange()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        pictureInPictureViewHierarchyDidChange()
    }

}

private struct MPVPlayerMetalLayerTransfer<Value>: @unchecked Sendable {
    let value: Value
}

final class MPVPlayerMetalLayer: CAMetalLayer, @unchecked Sendable {

    override var pixelFormat: MTLPixelFormat {
        get { super.pixelFormat }
        set {
            guard Thread.isMainThread == false else {
                super.pixelFormat = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.sync {
                transfer.value.0.pixelFormat = transfer.value.1
            }
        }
    }

    override var maximumDrawableCount: Int {
        get { super.maximumDrawableCount }
        set {
            guard Thread.isMainThread == false else {
                super.maximumDrawableCount = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.sync {
                transfer.value.0.maximumDrawableCount = transfer.value.1
            }
        }
    }

    override var minificationFilter: CALayerContentsFilter {
        get { super.minificationFilter }
        set {
            guard Thread.isMainThread == false else {
                super.minificationFilter = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.sync {
                transfer.value.0.minificationFilter = transfer.value.1
            }
        }
    }

    override var magnificationFilter: CALayerContentsFilter {
        get { super.magnificationFilter }
        set {
            guard Thread.isMainThread == false else {
                super.magnificationFilter = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.sync {
                transfer.value.0.magnificationFilter = transfer.value.1
            }
        }
    }

    override var contentsGravity: CALayerContentsGravity {
        get { super.contentsGravity }
        set {
            guard Thread.isMainThread == false else {
                super.contentsGravity = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.sync {
                transfer.value.0.contentsGravity = transfer.value.1
            }
        }
    }

    override var framebufferOnly: Bool {
        get { super.framebufferOnly }
        set {
            guard Thread.isMainThread == false else {
                super.framebufferOnly = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.sync {
                transfer.value.0.framebufferOnly = transfer.value.1
            }
        }
    }

    override var isOpaque: Bool {
        get { super.isOpaque }
        set {
            guard Thread.isMainThread == false else {
                super.isOpaque = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.sync {
                transfer.value.0.isOpaque = transfer.value.1
            }
        }
    }

    override var colorspace: CGColorSpace? {
        get { super.colorspace }
        set {
            guard Thread.isMainThread == false else {
                super.colorspace = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.sync {
                transfer.value.0.colorspace = transfer.value.1
            }
        }
    }

    override var drawableSize: CGSize {
        get {
            super.drawableSize
        }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                guard Thread.isMainThread == false else {
                    super.drawableSize = newValue
                    return
                }
                let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
                DispatchQueue.main.sync {
                    transfer.value.0.drawableSize = transfer.value.1
                }
            }
        }
    }

    override func setNeedsDisplay() {
        guard Thread.isMainThread == false else {
            super.setNeedsDisplay()
            return
        }
        let transfer = MPVPlayerMetalLayerTransfer(value: self)
        DispatchQueue.main.async {
            transfer.value.setNeedsDisplay()
        }
    }

    override func setNeedsDisplay(_ rect: CGRect) {
        guard Thread.isMainThread == false else {
            super.setNeedsDisplay(rect)
            return
        }
        let transfer = MPVPlayerMetalLayerTransfer(value: (self, rect))
        DispatchQueue.main.async {
            transfer.value.0.setNeedsDisplay(transfer.value.1)
        }
    }
}
