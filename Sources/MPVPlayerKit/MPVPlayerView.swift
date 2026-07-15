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

private enum MPVProperty {
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

private struct MPVSetupProfile {
    let name: String
    let options: [(String, String)]
}

private enum MPVVideoQualityPreset: Int {
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

private enum MPVContentModeSnapshot {
    case fit
    case fill

    init(contentModeRawValue: Int) {
        self = contentModeRawValue == UIView.ContentMode.scaleAspectFill.rawValue ? .fill : .fit
    }
}

@objc(MPVPlayerView)
public final class MPVPlayerView: UIView {
    private static let sharedMetalVideoOutputOptions: [(String, String)] = [
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

    private static let edrMetalVideoOutputOptions = sharedMetalVideoOutputOptions + [
        ("fbo-format", "rgba16f"),
        ("target-colorspace-hint", "yes"),
        ("target-colorspace-hint-mode", "source"),
    ]

    private static let dolbyVisionEDRMetalVideoOutputOptions = sharedMetalVideoOutputOptions + [
        ("fbo-format", "rgba16f"),
        ("target-colorspace-hint", "yes"),
        ("target-colorspace-hint-mode", "source-dynamic"),
    ]

    private static let sdrMetalVideoOutputOptions = sharedMetalVideoOutputOptions + [
        ("target-trc", "srgb"),
        ("target-prim", "bt.709"),
    ]

    @objc public private(set) var isPlaying = false
    @objc public private(set) var duration: TimeInterval = 0.0
    @objc public private(set) var currentTime: TimeInterval = 0.0

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

    private var metalLayer = MPVPlayerMetalLayer()
    private var usesExtendedDynamicRangeOutput = false
    private var url: URL?
    private var headers: [String: String] = [:]
    private var userAgent: String?
    private let queue = DispatchQueue(label: "com.mpvplayerkit.player", qos: .userInitiated)
    private let queueSpecificKey = DispatchSpecificKey<Void>()
    private let contentModeSnapshotLock = NSLock()
    private var contentModeSnapshot: MPVContentModeSnapshot = .fit
    private var mpv: OpaquePointer?
    private var timeTimer: DispatchSourceTimer?
    private var hasReportedReadyToPlay = false
    private var hasPlaybackRestarted = false
    private var hasLoggedVideoColorParameters = false
    private var stopped = false
    private var setupFailed = false
    private var forceSoftwareDecode = false
    private var isDolbyVisionPlayback = false
    private var currentSubtitleUsesOriginalStyle = false
    private var videoQualityPreset = MPVVideoQualityPreset.balanced
    private var debandEnabled = false
    private var interpolationOptions = MPVInterpolationOptions.off
    private var subtitleDelayValue = 0.0
    private var subtitleStyleValues: [String: String] = [
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
    private struct PendingExternalSubtitleLoad {
        let userdata: UInt64
        let selectionEpoch: UInt64
        let url: String
        let source: String
        let usesOriginalStyle: Bool
        let trackIDsBeforeLoad: Set<Int64>
        let previousSelection: SubtitleSelectionSnapshot
        var requestIDs: [String]
    }

    private struct SubtitleSelectionSnapshot {
        let usesOriginalStyle: Bool
        let subtitleID: Int64?
        let isVisible: Bool
    }

    private struct ExternalSubtitleActivation {
        let selectionEpoch: UInt64
        let subtitleID: Int64
        let previousSelection: SubtitleSelectionSnapshot
        var requestIDs: Set<String>
    }

    // Access only from `queue`; command reply handling runs on this queue as well.
    private var loadedExternalSubtitleIDs: [String: Int64] = [:]
    private var pendingExternalSubtitleLoad: PendingExternalSubtitleLoad?
    private var canceledExternalSubtitleCommands: [UInt64: PendingExternalSubtitleLoad] = [:]
    private var activeExternalSubtitleActivation: ExternalSubtitleActivation?
    private var committedSubtitleSelection: SubtitleSelectionSnapshot?
    private var nextSubtitleLoadUserdata: UInt64 = 1
    private var subtitleSelectionEpoch: UInt64 = 0
    private var lastLoggedSubtitleText = ""
    private var hasLoggedSubtitleTextEvent = false
    private var repeatedMPVLogMessageCounts: [String: Int] = [:]
    private var lastAppliedLayerBounds = CGRect.null
    private var lastAppliedDrawableSize = CGSize.zero
    private var videoOutputRefreshWorkItem: DispatchWorkItem?
    private var geometryTransitionOverlayView: UIView?
    private var geometryTransitionPreparedTargetSize = CGSize.zero
    private let geometryTransitionFallbackAlpha: CGFloat = 0.58
    private let geometryTransitionDimAlpha: CGFloat = 0.36
    private let geometryTransitionFadeOutDuration: TimeInterval = 0.32
    private var geometryTransitionAnimationID = 0
    private var setupProfiles: [MPVSetupProfile] = []
    private var activeSetupProfileIndex = 0

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

    private func setupLayer() {
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

    @objc public func prepareLayoutTransition(_ options: NSDictionary) {
        let targetSize = layoutTargetSize(from: options)
        mpvDebugLog("prepareLayoutTransition requested target=\(targetSize) bounds=\(bounds) drawable=\(metalLayer.drawableSize)")
        animateGeometryTransitionOut(targetSize: targetSize, reason: "prelayout")
    }

    @objc public func refreshLayout(_ options: NSDictionary) {
        let targetSize = layoutTargetSize(from: options)
        mpvDebugLog("refreshLayout requested width=\(targetSize.width) height=\(targetSize.height) bounds=\(bounds) drawable=\(metalLayer.drawableSize)")
        updateMetalLayerGeometryIfNeeded()
    }

    @objc public func play() {
        mpvDebugLog("play requested stopped=\(stopped) setupFailed=\(setupFailed) hasHandle=\(mpv != nil)")
        guard ensureMPVReady() else {
            return
        }
        setFlag(MPVProperty.pause, false)
        isPlaying = true
        notifyState(hasReportedReadyToPlay ? .bufferFinished : .buffering)
        startTimeTimer()
    }

    @objc public func pause() {
        guard mpv != nil else { return }
        mpvDebugLog("pause")
        setFlag(MPVProperty.pause, true)
        isPlaying = false
        stopTimeTimer()
        notifyState(.paused)
    }

    @objc public func stop() {
        setDecoderMode(.initializing)
        guard stopped == false else {
            mpvDebugLog("stop ignored already stopped")
            return
        }
        stopped = true
        destroyMPVHandle(reason: "stop")
    }

    @objc public func seek(_ options: NSDictionary) -> Bool {
        let time = (options["time"] as? NSNumber)?.doubleValue ?? 0.0
        let autoPlay = (options["autoPlay"] as? NSNumber)?.boolValue ?? false
        guard time.isFinite, mpv != nil else {
            return false
        }

        mpvDebugLog("seek time=\(max(0.0, time)) autoPlay=\(autoPlay)")
        let status = command("seek", args: [String(max(0.0, time)), "absolute+exact"])
        if autoPlay {
            play()
        }
        return status >= 0
    }

    @objc public func updatePlayRate(_ rate: NSNumber) {
        let value = rate.doubleValue
        guard value.isFinite, value > 0.0 else { return }
        mpvDebugLog("updatePlayRate value=\(value)")
        setDouble(MPVProperty.speed, value)
    }

    @objc public func updateVideoQuality(_ value: NSNumber) {
        let preset = MPVVideoQualityPreset(rawValue: value.intValue) ?? .balanced
        queue.async { [weak self] in
            guard let self else { return }
            self.videoQualityPreset = preset
            guard self.mpv != nil else { return }
            self.applyVideoQualityProperties(preset)
        }
    }

    @objc public func updateVideoRenderOptions(_ options: NSDictionary) {
        let debandEnabled = boolValue(options["debandEnabled"])
        let interpolationOptions = MPVInterpolationOptions(bridgeDictionary: options)
        queue.async { [weak self] in
            guard let self else { return }
            self.debandEnabled = debandEnabled
            self.interpolationOptions = interpolationOptions
            guard self.mpv != nil else { return }
            self.applyVideoRenderProperties()
        }
    }

    @objc public func mediaTracks(_ options: NSDictionary) -> NSArray {
        let requestedType = options["mediaType"] as? String
        let tracks = readMediaTracks(mediaType: requestedType)
        let summary = tracks.map { track in
            "id=\(track["trackID"] ?? "?") type=\(track["mpvType"] ?? "?") name=\(track["name"] ?? "?") selected=\(track["isEnabled"] ?? false)"
        }.joined(separator: " | ")
        mpvDebugLog("mediaTracks requested=\(requestedType ?? "<all>") count=\(tracks.count) tracks=[\(summary)]")
        return tracks as NSArray
    }

    @objc public func selectTrack(_ options: NSDictionary) {
        guard let trackID = (options["trackID"] as? NSNumber)?.int64Value,
              let mediaType = options["mediaType"] as? String,
              let property = mpvSelectionProperty(for: mediaType) else {
            mpvDebugLog("selectTrack invalid options=\(options)")
            return
        }

        let isImageSubtitle = boolValue(options["isImageSubtitle"])
        let usesNativeSubtitleRendering = boolValue(options["usesNativeSubtitleRendering"])
        let usesOriginalStyle = boolValue(options["usesOriginalStyle"])
        queue.async { [weak self] in
            guard let self else { return }
            if mediaType == "sub" {
                _ = self.beginNewSubtitleSelection(reason: "embedded-track")
                let snapshot = self.logicalSubtitleSelection()
                let visible = isImageSubtitle || usesNativeSubtitleRendering
                let success = self.performSubtitleSelectionTransaction(
                    previous: snapshot,
                    targetUsesOriginalStyle: usesOriginalStyle,
                    targetSubtitleID: trackID,
                    targetVisibility: visible
                )
                if success {
                    self.activeExternalSubtitleActivation = nil
                }
                self.mpvDebugLog("selectTrack subtitle transaction success=\(success) visible=\(visible) trackID=\(trackID)")
            } else {
                let status = self.command("set", args: [property, "\(trackID)"], checkForErrors: false)
                self.mpvDebugLog("selectTrack mediaType=\(mediaType) property=\(property) trackID=\(trackID) status=\(status)")
            }
        }
    }

    @objc public func loadSubtitle(_ options: NSDictionary) {
        guard let requestID = options["requestID"] as? String,
              let urlString = options["url"] as? String, urlString.isEmpty == false else {
            mpvDebugLog("loadSubtitle ignored missing url")
            return
        }
        let usesOriginalStyle = boolValue(options["usesOriginalStyle"])
        queue.async { [weak self] in
            self?.loadSubtitleOnMPVQueue(
                requestID: requestID,
                urlString: urlString,
                usesOriginalStyle: usesOriginalStyle
            )
        }
    }

    private func loadSubtitleOnMPVQueue(
        requestID: String,
        urlString: String,
        usesOriginalStyle: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let mpv else {
            notifySubtitleLoad(requestID: requestID, success: false)
            return
        }
        if var pending = pendingExternalSubtitleLoad, pending.url == urlString {
            pending.requestIDs.append(requestID)
            pendingExternalSubtitleLoad = pending
            mpvDebugLog("loadSubtitle merged request=\(requestID) userdata=\(pending.userdata)")
            return
        }

        let selectionEpoch = beginNewSubtitleSelection(reason: "external-load")
        let previousSelection = logicalSubtitleSelection()
        if let subtitleID = loadedExternalSubtitleIDs[urlString] {
            if performSubtitleSelectionTransaction(
                previous: previousSelection,
                targetUsesOriginalStyle: usesOriginalStyle,
                targetSubtitleID: subtitleID,
                targetVisibility: true
            ) {
                activeExternalSubtitleActivation = ExternalSubtitleActivation(
                    selectionEpoch: selectionEpoch,
                    subtitleID: subtitleID,
                    previousSelection: previousSelection,
                    requestIDs: [requestID]
                )
                mpvDebugLog("loadSubtitle reused sid=\(subtitleID) originalStyle=\(currentSubtitleUsesOriginalStyle)")
                notifySubtitleLoad(requestID: requestID, success: true)
                return
            }
            loadedExternalSubtitleIDs.removeValue(forKey: urlString)
        }

        let source = URL(string: urlString).map { $0.isFileURL ? $0.path : $0.absoluteString } ?? urlString
        let userdata = nextSubtitleLoadUserdata
        nextSubtitleLoadUserdata &+= 1
        pendingExternalSubtitleLoad = PendingExternalSubtitleLoad(
            userdata: userdata,
            selectionEpoch: selectionEpoch,
            url: urlString,
            source: source,
            usesOriginalStyle: usesOriginalStyle,
            trackIDsBeforeLoad: subtitleTrackIDs(),
            previousSelection: previousSelection,
            requestIDs: [requestID]
        )
        var cargs = makeCArgs("sub-add", [source, "auto"]).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }
        let status = mpv_command_async(mpv, userdata, &cargs)
        if status < 0 {
            pendingExternalSubtitleLoad = nil
            notifySubtitleLoad(requestID: requestID, success: false)
        }
        mpvDebugLog("loadSubtitle async request=\(requestID) userdata=\(userdata) status=\(status)")
    }

    @objc public func setSubtitleVisible(_ options: NSDictionary) {
        let visible = boolValue(options["visible"])
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.beginNewSubtitleSelection(reason: visible ? "visibility-on" : "visibility-off")
            let snapshot = self.logicalSubtitleSelection()
            let success = self.performSubtitleSelectionTransaction(
                previous: snapshot,
                targetUsesOriginalStyle: snapshot.usesOriginalStyle,
                targetSubtitleID: snapshot.subtitleID,
                targetVisibility: visible
            )
            if success { self.activeExternalSubtitleActivation = nil }
            self.mpvDebugLog("setSubtitleVisible visible=\(visible) transactionSuccess=\(success)")
        }
    }

    @objc public func cancelSubtitleLoad(_ options: NSDictionary) {
        guard let requestID = options["requestID"] as? String else { return }
        queue.async { [weak self] in
            self?.cancelExternalSubtitleRequestOnMPVQueue(requestID: requestID)
        }
    }

    @objc public func updateSubtitleStyle(_ options: NSDictionary) {
        let values = [
            MPVProperty.subtitleFontSize: decimalString(options["fontSize"], fallback: 38),
            MPVProperty.subtitleBold: boolValue(options["bold"]) ? "yes" : "no",
            MPVProperty.subtitleColor: options["textColor"] as? String ?? "#FFFFFFFF",
            MPVProperty.subtitleOutlineSize: decimalString(options["outlineSize"], fallback: 0),
            MPVProperty.subtitleOutlineColor: options["outlineColor"] as? String ?? "#FF000000",
            MPVProperty.subtitleShadowOffset: decimalString(options["shadowOffset"], fallback: 0),
            MPVProperty.subtitleBackColor: options["backgroundColor"] as? String ?? "#00000000",
            MPVProperty.subtitleBorderStyle: "outline-and-shadow",
            MPVProperty.subtitleMarginY: subtitleMarginYString(options["bottomOffset"]),
        ]
        queue.async { [weak self] in
            guard let self else { return }
            let previousValues = self.subtitleStyleValues
            self.subtitleStyleValues = values
            guard self.mpv != nil else {
                self.mpvDebugLog("updateSubtitleStyle deferred values=\(values)")
                return
            }
            guard self.currentSubtitleUsesOriginalStyle == false else {
                self.mpvDebugLog("updateSubtitleStyle stored but skipped for ASS/SSA original style")
                return
            }
            let snapshot = self.logicalSubtitleSelection()
            if self.performSubtitleSelectionTransaction(
                previous: snapshot,
                targetUsesOriginalStyle: false,
                targetSubtitleID: snapshot.subtitleID,
                targetVisibility: snapshot.isVisible
            ) == false {
                self.subtitleStyleValues = previousValues
                self.restoreSubtitleSelection(snapshot)
            }
        }
    }

    @objc public func updateSubtitleDelay(_ value: NSNumber) {
        let delay = value.doubleValue
        queue.async { [weak self] in
            guard let self else { return }
            self.subtitleDelayValue = delay.isFinite ? delay : 0
            guard self.mpv != nil else { return }
            self.setDouble(MPVProperty.subtitleDelay, self.subtitleDelayValue)
        }
    }

    @objc public func currentSubtitleText() -> NSString? {
        guard let text = getString(MPVProperty.subtitleText),
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return text as NSString
    }

    private func setupMPV() {
        guard let url else {
            mpvDebugLog("setupMPV failed missing url")
            failSetup()
            return
        }

        setupProfiles = makeSetupProfiles()
        activeSetupProfileIndex = 0
        mpvDebugLog("setupMPV begin url=\(redactedURLDescription(url)) bounds=\(bounds) headers=\(headers.count) profiles=\(setupProfiles.map(\.name).joined(separator: ","))")

        while activeSetupProfileIndex < setupProfiles.count {
            let profile = setupProfiles[activeSetupProfileIndex]
            if setupMPV(url: url, profile: profile) {
                return
            }
            activeSetupProfileIndex += 1
        }

        mpvDebugLog("setupMPV exhausted all profiles")
        failSetup()
    }

    private func makeSetupProfiles() -> [MPVSetupProfile] {
        #if targetEnvironment(simulator)
        let hardwareDecode = "no"
        #else
        let hardwareDecode = "videotoolbox"
        #endif

        let softwareProfile = MPVSetupProfile(
            name: "metal-software",
            options: metalVideoOutputOptions + [
                ("hwdec", "no"),
            ]
        )

        guard forceSoftwareDecode == false, hardwareDecode != "no" else {
            return [softwareProfile]
        }

        return [
            MPVSetupProfile(
                name: "metal-videotoolbox",
                options: metalVideoOutputOptions + [
                    ("hwdec", hardwareDecode),
                ]
            ),
            softwareProfile,
        ]
    }

    private var metalVideoOutputOptions: [(String, String)] {
        let colorOptions: [(String, String)]
        if usesExtendedDynamicRangeOutput && isDolbyVisionPlayback {
            colorOptions = Self.dolbyVisionEDRMetalVideoOutputOptions
        } else if usesExtendedDynamicRangeOutput {
            colorOptions = Self.edrMetalVideoOutputOptions
        } else {
            colorOptions = Self.sdrMetalVideoOutputOptions
        }
        return colorOptions + videoQualityPreset.options + videoRenderOptions
    }

    private func applyVideoQualityProperties(_ preset: MPVVideoQualityPreset) {
        preset.options.forEach { option in
            _ = command("set", args: [option.0, option.1], checkForErrors: false)
        }
        mpvDebugLog("video quality updated preset=\(preset) options=\(preset.options)")
        logEffectiveVideoSettings(reason: "quality-runtime")
    }

    private var videoRenderOptions: [(String, String)] {
        var options = [
            ("deband", debandEnabled ? "yes" : "no"),
            ("interpolation", interpolationOptions.quality == .off ? "no" : "yes"),
            ("video-sync", interpolationOptions.quality == .off ? "audio" : "display-resample"),
            ("tscale", interpolationOptions.temporalScaler.rawValue),
            ("interpolation-threshold", String(interpolationOptions.threshold)),
            ("tscale-clamp", String(interpolationOptions.clamp)),
            ("tscale-antiring", String(interpolationOptions.antiring)),
        ]
        if let blur = interpolationOptions.blur {
            options.append(("tscale-blur", String(blur)))
        }
        if let radius = interpolationOptions.radius {
            options.append(("tscale-radius", String(radius)))
        }
        return options
    }

    private func applyVideoRenderProperties() {
        videoRenderOptions.forEach { option in
            _ = command("set", args: [option.0, option.1], checkForErrors: false)
        }
        mpvDebugLog(
            "video render options updated deband=\(debandEnabled) interpolationQuality=\(interpolationOptions.quality) tscale=\(interpolationOptions.temporalScaler.rawValue)"
        )
        logEffectiveVideoSettings(reason: "render-runtime")
    }

    private func logEffectiveVideoSettings(reason: String) {
        let propertyNames = [
            "scale",
            "cscale",
            "dscale",
            "correct-downscaling",
            "sigmoid-upscaling",
            "deband",
            "interpolation",
            "video-sync",
            "tscale",
            "interpolation-threshold",
            "tscale-blur",
            "tscale-clamp",
            "tscale-radius",
            "tscale-antiring",
        ]
        let properties = propertyNames.map { name in
            "\(name)=\(getString(name) ?? "<unavailable>")"
        }
        .joined(separator: " ")
        mpvDebugLog(
            "video settings effective reason=\(reason) requestedQuality=\(videoQualityPreset) requestedDeband=\(debandEnabled) requestedInterpolationQuality=\(interpolationOptions.quality) properties=[\(properties)]"
        )
    }

    private func setupMPV(url: URL, profile: MPVSetupProfile) -> Bool {
        mpvDebugLog("setupMPV profile begin name=\(profile.name) index=\(activeSetupProfileIndex + 1)/\(setupProfiles.count)")
        performOnMPVQueueSync {
            currentSubtitleUsesOriginalStyle = false
            loadedExternalSubtitleIDs.removeAll(keepingCapacity: true)
            pendingExternalSubtitleLoad = nil
            canceledExternalSubtitleCommands.removeAll(keepingCapacity: true)
            activeExternalSubtitleActivation = nil
            committedSubtitleSelection = nil
            nextSubtitleLoadUserdata = 1
            subtitleSelectionEpoch = 0
        }
        lastLoggedSubtitleText = ""
        hasLoggedSubtitleTextEvent = false
        repeatedMPVLogMessageCounts.removeAll(keepingCapacity: true)
        mpv = mpv_create()
        guard let mpv else {
            mpvDebugLog("setupMPV mpv_create returned nil profile=\(profile.name)")
            return false
        }
        mpvDebugLog("setupMPV created handle=\(mpv)")

        #if DEBUG
        checkError(mpv_request_log_messages(mpv, "v"), operation: "request_log_messages", notifyOnFailure: false)
        #else
        checkError(mpv_request_log_messages(mpv, "no"), operation: "request_log_messages", notifyOnFailure: false)
        #endif

        var metalLayerHandle = Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
        guard checkError(
            mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayerHandle),
            operation: "set_option wid",
            notifyOnFailure: false
        ) else {
            destroyMPVHandle(reason: "profile-\(profile.name)-wid-failed", sendStopCommand: false)
            return false
        }

        for option in profile.options {
            guard checkError(
                mpv_set_option_string(mpv, option.0, option.1),
                operation: "set_option \(option.0)=\(option.1)",
                notifyOnFailure: false
            ) else {
                destroyMPVHandle(reason: "profile-\(profile.name)-option-\(option.0)-failed", sendStopCommand: false)
                return false
            }
        }
        configureGPUShaderCache(for: mpv)

        checkError(mpv_set_option_string(mpv, "video-rotate", "no"), operation: "set_option video-rotate", notifyOnFailure: false)
        checkError(mpv_set_option_string(mpv, "subs-fallback", "yes"), operation: "set_option subs-fallback", notifyOnFailure: false)
        checkError(mpv_set_option_string(mpv, "subs-match-os-language", "yes"), operation: "set_option subs-match-os-language", notifyOnFailure: false)
        checkError(mpv_set_option_string(mpv, "sub-auto", "no"), operation: "set_option sub-auto", notifyOnFailure: false)
        checkError(mpv_set_option_string(mpv, "embeddedfonts", "yes"), operation: "set_option embeddedfonts", notifyOnFailure: false)
        checkError(mpv_set_option_string(mpv, MPVProperty.subtitleVisibility, "no"), operation: "set_option sub-visibility", notifyOnFailure: false)
        checkError(
            mpv_set_option_string(mpv, MPVProperty.subtitleDelay, decimalString(subtitleDelayValue, fallback: 0)),
            operation: "set_option sub-delay",
            notifyOnFailure: false
        )
        configureSystemSubtitleFont(for: mpv)
        checkError(mpv_set_option_string(mpv, "sub-shaper", "complex"), operation: "set_option sub-shaper", notifyOnFailure: false)
        checkError(mpv_set_option_string(mpv, MPVProperty.subtitleASSOverride, "strip"), operation: "set_option sub-ass-override", notifyOnFailure: false)
        applyUserSubtitleStyleOptions(to: mpv)

        if let userAgent, userAgent.isEmpty == false {
            checkError(mpv_set_option_string(mpv, "user-agent", userAgent), operation: "set_option user-agent", notifyOnFailure: false)
        }

        let httpHeaders = makeMPVHTTPHeaderFields()
        mpvDebugLog("setupMPV http headers total=\(headers.count) forwarded=\(httpHeaders.fields.count) skippedAuthHeaders=\(httpHeaders.skippedAuthHeaders) profile=\(profile.name)")
        if httpHeaders.fields.isEmpty == false {
            checkError(
                mpv_set_option_string(mpv, "http-header-fields", httpHeaders.fields.joined(separator: ",")),
                operation: "set_option http-header-fields",
                notifyOnFailure: false
            )
        }

        guard checkError(mpv_initialize(mpv), operation: "initialize", notifyOnFailure: false) else {
            destroyMPVHandle(reason: "profile-\(profile.name)-initialize-failed", sendStopCommand: false)
            return false
        }
        applyContentMode(currentContentModeSnapshot())
        mpvDebugLog("setupMPV initialized profile=\(profile.name)")
        logEffectiveVideoSettings(reason: "setup")
        logEffectiveSubtitleConfiguration()
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.pausedForCache, MPV_FORMAT_FLAG),
            operation: "observe paused-for-cache",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.subtitleText, MPV_FORMAT_STRING),
            operation: "observe sub-text",
            notifyOnFailure: false
        )
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let playerView = Unmanaged<MPVPlayerView>.fromOpaque(context).takeUnretainedValue()
            playerView.readEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
        mpvDebugLog("setupMPV wakeup callback installed profile=\(profile.name)")

        notifyState(.buffering)
        let loadStatus = command("loadfile", args: [url.absoluteString, "replace"], checkForErrors: false)
        guard loadStatus >= 0 else {
            mpvDebugLog("setupMPV loadfile failed profile=\(profile.name) status=\(loadStatus)")
            destroyMPVHandle(reason: "profile-\(profile.name)-loadfile-failed", sendStopCommand: false)
            return false
        }
        mpvDebugLog("setupMPV profile ready name=\(profile.name)")
        return true
    }

    private func configureGPUShaderCache(for handle: OpaquePointer) {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            mpvDebugLog("gpu shader cache skipped missing caches directory")
            return
        }
        let directory = cachesDirectory.appendingPathComponent("MPVPlayerKit/ShaderCache", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            checkError(
                mpv_set_option_string(handle, "gpu-shader-cache-dir", directory.path),
                operation: "set_option gpu-shader-cache-dir",
                notifyOnFailure: false
            )
            mpvDebugLog("gpu shader cache configured")
        } catch {
            mpvDebugLog("gpu shader cache create failed error=\(error.localizedDescription)")
        }
    }

    private func configureSystemSubtitleFont(for handle: OpaquePointer) {
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle(for: MPVPlayerView.self)
        #endif
        let requiredFontResources: [(String, String)] = [
            ("NotoSansSC-Regular", "otf"),
            ("NotoSansCJK-Regular", "ttc"),
            ("NotoSansCJK-Bold", "ttc"),
            ("NotoSans-Variable", "ttf"),
            ("NotoSansArabic-Variable", "ttf"),
            ("NotoSansHebrew-Variable", "ttf"),
            ("NotoSansThai-Variable", "ttf"),
            ("NotoSansDevanagari-Variable", "ttf"),
        ]
        let missingFontResources = requiredFontResources.compactMap { name, fileExtension in
            resourceBundle.url(forResource: name, withExtension: fileExtension) == nil
                ? "\(name).\(fileExtension)"
                : nil
        }
        guard missingFontResources.isEmpty else {
            mpvDebugLog("bundled subtitle fonts missing resources=\(missingFontResources.joined(separator: ","))")
            return
        }
        guard let fontURL = resourceBundle.url(forResource: "NotoSansSC-Regular", withExtension: "otf") else {
            mpvDebugLog("bundled subtitle font missing")
            return
        }
        checkError(
            mpv_set_option_string(handle, MPVProperty.subtitleFontProvider, "auto"),
            operation: "set_option sub-font-provider=auto",
            notifyOnFailure: false
        )
        checkError(
            mpv_set_option_string(handle, "sub-fonts-dir", fontURL.deletingLastPathComponent().path),
            operation: "set_option sub-fonts-dir",
            notifyOnFailure: false
        )
        checkError(
            mpv_set_option_string(handle, MPVProperty.subtitleFont, "NotoSansSC-Regular"),
            operation: "set_option sub-font=NotoSansSC-Regular",
            notifyOnFailure: false
        )
        mpvDebugLog("bundled subtitle fonts configured default=NotoSansSC-Regular count=\(requiredFontResources.count)")
    }

    private func ensureMPVReady() -> Bool {
        if mpv != nil {
            return true
        }
        guard stopped == false, setupFailed == false else {
            notifyState(.error)
            return false
        }
        setupMPV()
        return mpv != nil
    }

    private func failSetup() {
        setupFailed = true
        destroyMPVHandle(reason: "setup-failed")
        notifyState(.error)
    }

    private func destroyMPVHandle(reason: String, sendStopCommand: Bool = true) {
        setDecoderMode(.initializing)
        stopTimeTimer()
        videoOutputRefreshWorkItem?.cancel()
        videoOutputRefreshWorkItem = nil
        lastLoggedSubtitleText = ""
        hasLoggedSubtitleTextEvent = false
        resetGeometryTransitionAnimation()
        performOnMPVQueueSync {
            let pendingRequestIDs = pendingExternalSubtitleLoad?.requestIDs ?? []
            if let mpv, let pending = pendingExternalSubtitleLoad {
                mpv_abort_async_command(mpv, pending.userdata)
            }
            pendingExternalSubtitleLoad = nil
            loadedExternalSubtitleIDs.removeAll(keepingCapacity: true)
            canceledExternalSubtitleCommands.removeAll(keepingCapacity: true)
            activeExternalSubtitleActivation = nil
            committedSubtitleSelection = nil
            nextSubtitleLoadUserdata = 1
            subtitleSelectionEpoch = 0
            currentSubtitleUsesOriginalStyle = false
            pendingRequestIDs.forEach { notifySubtitleLoad(requestID: $0, success: false) }
            guard let mpv else {
                mpvDebugLog("destroyMPVHandle skipped reason=\(reason) handle=nil")
                return
            }
            mpvDebugLog("destroyMPVHandle begin reason=\(reason) handle=\(mpv)")
            mpv_set_wakeup_callback(mpv, nil, nil)
            self.mpv = nil
            if sendStopCommand {
                let stopStatus = command("stop", handle: mpv, checkForErrors: false)
                mpvDebugLog("destroyMPVHandle stop command status=\(stopStatus)")
            }
            mpv_terminate_destroy(mpv)
            mpvDebugLog("destroyMPVHandle end reason=\(reason)")
        }
    }

    private func setContentModeSnapshot(_ contentModeSnapshot: MPVContentModeSnapshot) {
        contentModeSnapshotLock.lock()
        self.contentModeSnapshot = contentModeSnapshot
        contentModeSnapshotLock.unlock()
    }

    private func currentContentModeSnapshot() -> MPVContentModeSnapshot {
        contentModeSnapshotLock.lock()
        defer { contentModeSnapshotLock.unlock() }
        return contentModeSnapshot
    }

    private func applyContentMode(_ contentModeSnapshot: MPVContentModeSnapshot) {
        switch contentModeSnapshot {
        case .fill:
            setDouble(MPVProperty.panscan, 1.0)
        case .fit:
            setDouble(MPVProperty.panscan, 0.0)
        }
    }

    private func applyContentMode(_ contentMode: UIView.ContentMode) {
        applyContentMode(MPVContentModeSnapshot(contentModeRawValue: contentMode.rawValue))
    }

    private func layoutTargetSize(from options: NSDictionary) -> CGSize {
        let width = (options["width"] as? NSNumber)?.doubleValue ?? Double(bounds.width)
        let height = (options["height"] as? NSNumber)?.doubleValue ?? Double(bounds.height)
        return CGSize(width: width, height: height)
    }

    private func updateMetalLayerGeometryIfNeeded() {
        if Thread.isMainThread == false {
            DispatchQueue.main.async { [weak self] in
                self?.updateMetalLayerGeometryIfNeeded()
            }
            return
        }

        let scale = UIScreen.main.nativeScale
        let layerBounds = CGRect(origin: .zero, size: bounds.size)
        let drawableSize = CGSize(
            width: bounds.size.width * scale,
            height: bounds.size.height * scale
        )
        let geometryChanged = hasMetalGeometryChanged(
            layerBounds: layerBounds,
            drawableSize: drawableSize
        )

        if mpv != nil, geometryChanged {
            animateGeometryTransitionOut(targetSize: layerBounds.size, reason: "layout")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = layerBounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = drawableSize
        CATransaction.commit()

        lastAppliedLayerBounds = layerBounds
        lastAppliedDrawableSize = drawableSize

        if mpv != nil, geometryChanged {
            mpvDebugLog("metal geometry changed bounds=\(layerBounds) drawable=\(drawableSize) scale=\(scale)")
            applyContentMode(contentMode)
            scheduleVideoOutputRefresh(drawableSize: drawableSize, layerBounds: layerBounds, contentMode: contentMode)
        }
    }

    private func hasMetalGeometryChanged(layerBounds: CGRect, drawableSize: CGSize) -> Bool {
        guard layerBounds.width > 1.0, layerBounds.height > 1.0 else {
            return false
        }
        if lastAppliedLayerBounds.isNull {
            return true
        }
        return abs(lastAppliedLayerBounds.width - layerBounds.width) > 0.5
            || abs(lastAppliedLayerBounds.height - layerBounds.height) > 0.5
            || abs(lastAppliedDrawableSize.width - drawableSize.width) > 0.5
            || abs(lastAppliedDrawableSize.height - drawableSize.height) > 0.5
    }

    private func scheduleVideoOutputRefresh(drawableSize: CGSize, layerBounds: CGRect, contentMode: UIView.ContentMode) {
        videoOutputRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.refreshVideoOutputAfterGeometryChange(
                drawableSize: drawableSize,
                layerBounds: layerBounds,
                contentMode: contentMode
            )
        }
        videoOutputRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func refreshVideoOutputAfterGeometryChange(drawableSize: CGSize, layerBounds: CGRect, contentMode: UIView.ContentMode) {
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv, self.stopped == false else { return }
            self.mpvDebugLog("video output refresh begin bounds=\(layerBounds) drawable=\(drawableSize)")
            self.checkError(
                mpv_set_option_string(mpv, "vid", "no"),
                operation: "layout refresh vid=no",
                notifyOnFailure: false
            )
            self.checkError(
                mpv_set_option_string(mpv, "vid", "auto"),
                operation: "layout refresh vid=auto",
                notifyOnFailure: false
            )
            self.applyContentMode(contentMode)
            self.mpvDebugLog("video output refresh end bounds=\(layerBounds) drawable=\(drawableSize)")
            DispatchQueue.main.async { [weak self] in
                self?.animateGeometryTransitionIn()
            }
        }
    }

    private func animateGeometryTransitionOut(targetSize: CGSize, reason: String) {
        prepareGeometryTransitionOverlay(targetSize: targetSize, reason: reason)
    }

    private func prepareGeometryTransitionOverlay(targetSize: CGSize, reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.prepareGeometryTransitionOverlay(targetSize: targetSize, reason: reason)
            }
            return
        }
        guard mpv != nil else {
            return
        }
        guard UIAccessibility.isReduceMotionEnabled == false else {
            resetGeometryTransitionAnimation(reason: "reduce-motion")
            return
        }
        guard targetSize.width > 1.0, targetSize.height > 1.0, bounds.width > 1.0, bounds.height > 1.0 else {
            return
        }
        if geometryTransitionOverlayView != nil,
           isLayoutSizeClose(geometryTransitionPreparedTargetSize, targetSize) {
            return
        }
        guard isLayoutSizeClose(targetSize, bounds.size) == false else {
            mpvDebugLog("geometry transition skipped reason=\(reason) sameSize bounds=\(bounds) target=\(targetSize)")
            resetGeometryTransitionAnimation(reason: "same-size-\(reason)")
            return
        }

        geometryTransitionAnimationID += 1
        geometryTransitionPreparedTargetSize = targetSize
        geometryTransitionOverlayView?.removeFromSuperview()

        guard let snapshotView = snapshotView(afterScreenUpdates: false)
            ?? resizableSnapshotView(from: bounds, afterScreenUpdates: false, withCapInsets: .zero) else {
            mpvDebugLog("geometry transition skipped reason=\(reason) noSnapshot bounds=\(bounds) target=\(targetSize)")
            resetGeometryTransitionAnimation(reason: "no-snapshot-\(reason)")
            return
        }

        let overlayView = UIView(frame: bounds)
        overlayView.isUserInteractionEnabled = false
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.backgroundColor = UIColor.black.withAlphaComponent(geometryTransitionFallbackAlpha)

        snapshotView.frame = overlayView.bounds
        snapshotView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.addSubview(snapshotView)

        let dimView = UIView(frame: overlayView.bounds)
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.backgroundColor = .black
        dimView.alpha = geometryTransitionDimAlpha
        overlayView.addSubview(dimView)

        addSubview(overlayView)
        bringSubviewToFront(overlayView)
        geometryTransitionOverlayView = overlayView
        let transitionID = geometryTransitionAnimationID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak overlayView] in
            guard let self,
                  self.geometryTransitionAnimationID == transitionID,
                  self.geometryTransitionOverlayView === overlayView else {
                return
            }
            self.mpvDebugLog("geometry transition overlay timeout fade out id=\(transitionID) reason=\(reason) bounds=\(self.bounds) target=\(targetSize)")
            self.animateGeometryTransitionIn()
        }
        mpvDebugLog("geometry transition overlay prepared id=\(geometryTransitionAnimationID) reason=\(reason) bounds=\(bounds) target=\(targetSize) hasSnapshot=true fallbackAlpha=\(geometryTransitionFallbackAlpha) dimAlpha=\(geometryTransitionDimAlpha)")
    }

    private func animateGeometryTransitionIn() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.animateGeometryTransitionIn()
            }
            return
        }
        guard UIAccessibility.isReduceMotionEnabled == false else {
            resetGeometryTransitionAnimation(reason: "reduce-motion")
            return
        }
        geometryTransitionAnimationID += 1
        geometryTransitionPreparedTargetSize = .zero
        let transitionID = geometryTransitionAnimationID
        guard let overlayView = geometryTransitionOverlayView else {
            return
        }
        mpvDebugLog("geometry transition overlay fade out id=\(transitionID) bounds=\(bounds)")
        UIView.animate(
            withDuration: geometryTransitionFadeOutDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            overlayView.alpha = 0.0
        } completion: { [weak self, weak overlayView] _ in
            guard let self else { return }
            if self.geometryTransitionAnimationID == transitionID {
                self.geometryTransitionOverlayView = nil
            }
            overlayView?.removeFromSuperview()
        }
    }

    private func resetGeometryTransitionAnimation(reason: String = "reset") {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.resetGeometryTransitionAnimation(reason: reason)
            }
            return
        }
        let hadOverlay = geometryTransitionOverlayView != nil
        geometryTransitionAnimationID += 1
        geometryTransitionPreparedTargetSize = .zero
        geometryTransitionOverlayView?.layer.removeAllAnimations()
        geometryTransitionOverlayView?.removeFromSuperview()
        geometryTransitionOverlayView = nil
        mpvDebugLog("geometry transition reset reason=\(reason) hadOverlay=\(hadOverlay) id=\(geometryTransitionAnimationID)")
    }

    private func isLayoutSizeClose(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
    }

    private func startTimeTimer() {
        guard timeTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(500),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.publishTime()
        }
        timeTimer = timer
        timer.resume()
    }

    private func stopTimeTimer() {
        timeTimer?.setEventHandler {}
        timeTimer?.cancel()
        timeTimer = nil
    }

    private func publishTime() {
        guard mpv != nil else { return }
        let current = getDouble(MPVProperty.timePosition)
        let total = getDouble(MPVProperty.duration)
        guard current.isFinite else { return }

        let nextCurrentTime = max(0.0, current)
        let nextDuration = total.isFinite && total > 0.0 ? total : nil
        notifyOnMain {
            guard self.mpv != nil else { return }
            self.currentTime = nextCurrentTime
            if let nextDuration {
                self.duration = nextDuration
            }

            if self.hasReportedReadyToPlay == false, self.duration > 0.0 {
                self.hasReportedReadyToPlay = true
                self.notifyState(.readyToPlay)
            }
            self.notifyTime(currentTime: self.currentTime, duration: self.duration)
        }
    }

    private func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.mpv {
                guard let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE else {
                    break
                }

                switch event.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    self.handlePropertyChange(event)
                case MPV_EVENT_PLAYBACK_RESTART:
                    self.hasPlaybackRestarted = true
                    self.mpvDebugLog("event playback-restart profile=\(self.activeProfileDescription)")
                    self.refreshDecoderModeAfterPlaybackRestart()
                    if self.hasLoggedVideoColorParameters == false {
                        self.hasLoggedVideoColorParameters = true
                        self.logVideoColorParameters()
                    }
                case MPV_EVENT_END_FILE:
                    self.handleEndFile(event)
                case MPV_EVENT_SHUTDOWN:
                    self.notifyOnMain {
                        self.stopTimeTimer()
                        self.isPlaying = false
                    }
                case MPV_EVENT_LOG_MESSAGE:
                    self.logMessage(event)
                case MPV_EVENT_COMMAND_REPLY:
                    self.handleCommandReply(event)
                default:
                    break
                }
            }
        }
    }

    private func handleCommandReply(_ event: UnsafeMutablePointer<mpv_event>) {
        dispatchPrecondition(condition: .onQueue(queue))
        let userdata = event.pointee.reply_userdata
        if let canceled = canceledExternalSubtitleCommands.removeValue(forKey: userdata) {
            restoreAfterStaleExternalReplyIfNeeded(canceled)
            return
        }
        guard let pending = pendingExternalSubtitleLoad,
              pending.userdata == userdata,
              pending.selectionEpoch == subtitleSelectionEpoch else { return }
        pendingExternalSubtitleLoad = nil
        let subtitleID = event.pointee.error >= 0
            ? externalSubtitleTrackID(
                source: pending.source,
                urlString: pending.url,
                preferringIDsNotIn: pending.trackIDsBeforeLoad
            )
            : nil
        let success = subtitleID.map { subtitleID in
            performSubtitleSelectionTransaction(
                previous: pending.previousSelection,
                targetUsesOriginalStyle: pending.usesOriginalStyle,
                targetSubtitleID: subtitleID,
                targetVisibility: true
            )
        } ?? false
        if success, let subtitleID {
            loadedExternalSubtitleIDs[pending.url] = subtitleID
            activeExternalSubtitleActivation = ExternalSubtitleActivation(
                selectionEpoch: pending.selectionEpoch,
                subtitleID: subtitleID,
                previousSelection: pending.previousSelection,
                requestIDs: Set(pending.requestIDs)
            )
        }
        mpvDebugLog("loadSubtitle reply requests=\(pending.requestIDs) userdata=\(userdata) sid=\(subtitleID.map(String.init) ?? "nil") success=\(success) error=\(event.pointee.error)")
        pending.requestIDs.forEach { notifySubtitleLoad(requestID: $0, success: success) }
    }

    private func cancelPendingExternalSubtitleLoad(handle: OpaquePointer, reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let pending = pendingExternalSubtitleLoad else { return }
        pendingExternalSubtitleLoad = nil
        canceledExternalSubtitleCommands[pending.userdata] = pending
        mpv_abort_async_command(handle, pending.userdata)
        if restoreSubtitleSelection(pending.previousSelection) == false {
            mpvDebugLog("loadSubtitle cancel restore failed userdata=\(pending.userdata) reason=\(reason)")
        }
        mpvDebugLog("loadSubtitle cancelled userdata=\(pending.userdata) reason=\(reason)")
        pending.requestIDs.forEach { notifySubtitleLoad(requestID: $0, success: false) }
    }

    @discardableResult
    private func beginNewSubtitleSelection(reason: String) -> UInt64 {
        dispatchPrecondition(condition: .onQueue(queue))
        subtitleSelectionEpoch &+= 1
        if let mpv {
            cancelPendingExternalSubtitleLoad(handle: mpv, reason: reason)
        } else if let pending = pendingExternalSubtitleLoad {
            pendingExternalSubtitleLoad = nil
            pending.requestIDs.forEach { notifySubtitleLoad(requestID: $0, success: false) }
        }
        activeExternalSubtitleActivation = nil
        return subtitleSelectionEpoch
    }

    private func captureSubtitleSelection() -> SubtitleSelectionSnapshot {
        SubtitleSelectionSnapshot(
            usesOriginalStyle: currentSubtitleUsesOriginalStyle,
            subtitleID: getInt64(MPVProperty.subtitleID),
            isVisible: getFlag(MPVProperty.subtitleVisibility) ?? false
        )
    }

    private func logicalSubtitleSelection() -> SubtitleSelectionSnapshot {
        if let committedSubtitleSelection { return committedSubtitleSelection }
        let initial = captureSubtitleSelection()
        committedSubtitleSelection = initial
        return initial
    }

    private func performSubtitleSelectionTransaction(
        previous: SubtitleSelectionSnapshot,
        targetUsesOriginalStyle: Bool,
        targetSubtitleID: Int64?,
        targetVisibility: Bool
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        _ = command("set", args: [MPVProperty.subtitleVisibility, "no"], checkForErrors: false)
        let styleSucceeded = applySubtitleStyleMode(usesOriginalStyle: targetUsesOriginalStyle)
        let sidSucceeded = command(
            "set",
            args: [MPVProperty.subtitleID, targetSubtitleID.map(String.init) ?? "no"],
            checkForErrors: false
        ) >= 0
        let visibilitySucceeded = command(
            "set",
            args: [MPVProperty.subtitleVisibility, targetVisibility ? "yes" : "no"],
            checkForErrors: false
        ) >= 0
        guard styleSucceeded, sidSucceeded, visibilitySucceeded else {
            if restoreSubtitleSelection(previous) == false {
                enterSafeSubtitleState(reason: "transaction-rollback-failed")
            }
            return false
        }
        currentSubtitleUsesOriginalStyle = targetUsesOriginalStyle
        committedSubtitleSelection = SubtitleSelectionSnapshot(
            usesOriginalStyle: targetUsesOriginalStyle,
            subtitleID: targetSubtitleID,
            isVisible: targetVisibility
        )
        return true
    }

    @discardableResult
    private func restoreSubtitleSelection(_ snapshot: SubtitleSelectionSnapshot) -> Bool {
        let hideSucceeded = command("set", args: [MPVProperty.subtitleVisibility, "no"], checkForErrors: false) >= 0
        let styleSucceeded = applySubtitleStyleMode(usesOriginalStyle: snapshot.usesOriginalStyle)
        let sidSucceeded = command(
            "set",
            args: [MPVProperty.subtitleID, snapshot.subtitleID.map(String.init) ?? "no"],
            checkForErrors: false
        ) >= 0
        let visibilitySucceeded = command(
            "set",
            args: [MPVProperty.subtitleVisibility, snapshot.isVisible ? "yes" : "no"],
            checkForErrors: false
        ) >= 0
        guard hideSucceeded, styleSucceeded, sidSucceeded, visibilitySucceeded else { return false }
        currentSubtitleUsesOriginalStyle = snapshot.usesOriginalStyle
        committedSubtitleSelection = snapshot
        return true
    }

    private func enterSafeSubtitleState(reason: String) {
        let hidden = command("set", args: [MPVProperty.subtitleVisibility, "no"], checkForErrors: false) >= 0
        let disabled = command("set", args: [MPVProperty.subtitleID, "no"], checkForErrors: false) >= 0
        if hidden, disabled {
            if let override = getString(MPVProperty.subtitleASSOverride) {
                currentSubtitleUsesOriginalStyle = override == "no"
            }
            committedSubtitleSelection = SubtitleSelectionSnapshot(
                usesOriginalStyle: currentSubtitleUsesOriginalStyle,
                subtitleID: nil,
                isVisible: false
            )
        } else {
            committedSubtitleSelection = nil
        }
        mpvDebugLog("subtitle entered safe state reason=\(reason) hidden=\(hidden) disabled=\(disabled)")
        // Subtitle recovery failures are non-fatal to video playback. Keep the
        // video running with subtitles disabled instead of publishing the
        // global player error state, which presents the playback failure UI.
    }

    private func cancelExternalSubtitleRequestOnMPVQueue(requestID: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        if var pending = pendingExternalSubtitleLoad, pending.requestIDs.contains(requestID) {
            pending.requestIDs.removeAll(where: { $0 == requestID })
            if pending.requestIDs.isEmpty {
                pendingExternalSubtitleLoad = nil
                canceledExternalSubtitleCommands[pending.userdata] = pending
                subtitleSelectionEpoch &+= 1
                if let mpv { mpv_abort_async_command(mpv, pending.userdata) }
                if restoreSubtitleSelection(pending.previousSelection) == false {
                    enterSafeSubtitleState(reason: "cancel-pending-restore-failed")
                }
            } else {
                pendingExternalSubtitleLoad = pending
            }
            notifySubtitleLoad(requestID: requestID, success: false)
            return
        }
        if var activation = activeExternalSubtitleActivation,
           activation.requestIDs.remove(requestID) != nil {
            if activation.requestIDs.isEmpty {
                if activation.selectionEpoch == subtitleSelectionEpoch,
                   getInt64(MPVProperty.subtitleID) == activation.subtitleID {
                    subtitleSelectionEpoch &+= 1
                    if restoreSubtitleSelection(activation.previousSelection) == false {
                        enterSafeSubtitleState(reason: "cancel-activation-restore-failed")
                    }
                }
                activeExternalSubtitleActivation = nil
            } else {
                activeExternalSubtitleActivation = activation
            }
        }
        notifySubtitleLoad(requestID: requestID, success: false)
    }

    private func restoreAfterStaleExternalReplyIfNeeded(_ canceled: PendingExternalSubtitleLoad) {
        guard let staleSubtitleID = externalSubtitleTrackID(
            source: canceled.source,
            urlString: canceled.url,
            preferringIDsNotIn: canceled.trackIDsBeforeLoad
        ), canceled.trackIDsBeforeLoad.contains(staleSubtitleID) == false,
           getInt64(MPVProperty.subtitleID) == staleSubtitleID else { return }
        // A canceled `sub-add auto` selected itself in a special auto-selection case.
        // Restore the selection that is current at reply time, unless no newer selection committed.
        guard let committedSubtitleSelection else {
            enterSafeSubtitleState(reason: "stale-reply-missing-committed-selection")
            return
        }
        if restoreSubtitleSelection(committedSubtitleSelection) == false {
            enterSafeSubtitleState(reason: "stale-reply-restore-failed")
        }
    }

    private func notifySubtitleLoad(requestID: String, success: Bool) {
        notifyOnMain {
            NotificationCenter.default.post(
                name: MPVPlayerKitNotification.didLoadSubtitle,
                object: self,
                userInfo: [
                    MPVPlayerKitNotificationKey.requestID: requestID,
                    MPVPlayerKitNotificationKey.success: success,
                ]
            )
        }
    }

    private func handleEndFile(_ event: UnsafeMutablePointer<mpv_event>) {
        let endFile = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        let errorCode = endFile?.error ?? 0
        let errorMessage = errorCode == 0 ? "none" : String(cString: mpv_error_string(errorCode))
        guard let reason = endFile?.reason else {
            mpvDebugLog("event end-file missing reason error=\(errorCode) message=\(errorMessage) profile=\(activeProfileDescription)")
            if retryNextProfileAfterPlaybackFailure(errorCode: errorCode) {
                return
            }
            notifyOnMain {
                self.stopTimeTimer()
                self.isPlaying = false
                self.notifyState(.error)
            }
            return
        }
        mpvDebugLog("event end-file reason=\(String(describing: reason)) error=\(errorCode) message=\(errorMessage) profile=\(activeProfileDescription) hasReady=\(hasReportedReadyToPlay) hasRestarted=\(hasPlaybackRestarted)")

        if reason == MPV_END_FILE_REASON_ERROR {
            if retryNextProfileAfterPlaybackFailure(errorCode: errorCode) {
                return
            }
            notifyOnMain {
                self.stopTimeTimer()
                self.isPlaying = false
                self.notifyState(.error)
            }
            return
        }

        if reason == MPV_END_FILE_REASON_EOF {
            notifyOnMain {
                self.stopTimeTimer()
                self.isPlaying = false
                self.notifyState(.playedToTheEnd)
            }
            return
        }

        if reason == MPV_END_FILE_REASON_STOP || reason == MPV_END_FILE_REASON_QUIT || reason == MPV_END_FILE_REASON_REDIRECT {
            notifyOnMain {
                self.stopTimeTimer()
                self.isPlaying = false
            }
            return
        }

        if retryNextProfileAfterPlaybackFailure(errorCode: errorCode) {
            return
        }
        notifyOnMain {
            self.stopTimeTimer()
            self.isPlaying = false
            self.notifyState(.error)
        }
    }

    private func retryNextProfileAfterPlaybackFailure(errorCode: CInt) -> Bool {
        guard hasReportedReadyToPlay == false, hasPlaybackRestarted == false else {
            mpvDebugLog("profile retry skipped playback already started profile=\(activeProfileDescription) error=\(errorCode)")
            return false
        }
        guard let url else {
            mpvDebugLog("profile retry skipped missing url error=\(errorCode)")
            return false
        }
        let nextIndex = activeSetupProfileIndex + 1
        guard nextIndex < setupProfiles.count else {
            mpvDebugLog("profile retry skipped no more profiles current=\(activeProfileDescription) error=\(errorCode)")
            return false
        }

        let oldProfile = activeProfileDescription
        destroyMPVHandle(reason: "profile-\(oldProfile)-end-file-error-\(errorCode)", sendStopCommand: false)
        activeSetupProfileIndex = nextIndex
        hasReportedReadyToPlay = false
        hasPlaybackRestarted = false
        mpvDebugLog("profile retry next old=\(oldProfile) next=\(activeProfileDescription) error=\(errorCode)")
        return setupMPV(url: url, profile: setupProfiles[activeSetupProfileIndex])
    }

    private func handlePropertyChange(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let data = event.pointee.data else {
            return
        }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        let propertyName = String(cString: property.name)
        switch propertyName {
        case MPVProperty.pausedForCache:
            let bufferingValue = property.data?.assumingMemoryBound(to: Int32.self).pointee ?? 0
            let buffering = bufferingValue != 0
            if buffering {
                stopTimeTimer()
            } else if isPlaying {
                startTimeTimer()
            }
            notifyOnMain {
                self.notifyBufferingProgress(buffering ? 0 : 100)
                self.notifyState(buffering ? .buffering : .bufferFinished)
            }
        case MPVProperty.subtitleText:
            logSubtitleTextChange()
        default:
            break
        }
    }

    private func logEffectiveSubtitleConfiguration() {
        #if DEBUG
        let optionNames = [
            "sub-font-provider",
            "sub-font",
            "sub-fonts-dir",
            "sub-ass-override",
            "sub-shaper",
            "embeddedfonts",
            "sub-auto",
            "blend-subtitles",
            "gpu-shader-cache",
            "gpu-shader-cache-dir",
        ]
        let options = optionNames.map { name in
            "\(name)=\(getString("options/\(name)") ?? "<unavailable>")"
        }.joined(separator: " ")
        let systemFont = UIFont(name: "PingFangSC-Regular", size: 20)
        let resolvedFont = systemFont.map { "fontName=\($0.fontName) family=\($0.familyName)" } ?? "unavailable"
        mpvDebugLog("subtitle diagnostics options \(options)")
        mpvDebugLog("subtitle diagnostics CoreText font \(resolvedFont)")
        #endif
    }

    private func logSubtitleTextChange() {
        #if DEBUG
        let text = getString(MPVProperty.subtitleText) ?? ""
        guard hasLoggedSubtitleTextEvent == false || text != lastLoggedSubtitleText else { return }
        hasLoggedSubtitleTextEvent = true
        lastLoggedSubtitleText = text

        let codepoints = text.unicodeScalars.prefix(24).map { scalar in
            String(format: "U+%04X", scalar.value)
        }.joined(separator: ",")
        let truncated = text.unicodeScalars.count > 24 ? ",..." : ""
        let time = String(format: "%.3f", getDouble(MPVProperty.timePosition))
        let subtitleID = getInt64(MPVProperty.subtitleID).map(String.init) ?? "<none>"
        let visible = getFlag(MPVProperty.subtitleVisibility).map { $0 ? "yes" : "no" } ?? "<unknown>"
        mpvDebugLog(
            "subtitle text changed time=\(time) sid=\(subtitleID) visible=\(visible) "
                + "utf16=\(text.utf16.count) scalars=\(text.unicodeScalars.count) codepoints=[\(codepoints)\(truncated)]"
        )
        #endif
    }

    private func logMessage(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let data = event.pointee.data else { return }
        let message = data.assumingMemoryBound(to: mpv_event_log_message.self)
        let prefix = String(cString: message.pointee.prefix)
        let level = String(cString: message.pointee.level)
        let text = String(cString: message.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        guard shouldPrintMPVLogMessage(prefix: prefix, level: level, text: text) else { return }
        let repetitionKey = "\(prefix)\u{0}\(level)\u{0}\(text)"
        let repetitionCount = (repeatedMPVLogMessageCounts[repetitionKey] ?? 0) + 1
        repeatedMPVLogMessageCounts[repetitionKey] = repetitionCount
        guard repetitionCount <= 3 || repetitionCount.isMultiple(of: 100) else { return }
        let repetitionSuffix = repetitionCount > 1 ? " repeated=\(repetitionCount)" : ""
        print("mpv [\(prefix)] \(level): \(text)\(repetitionSuffix)")
        #endif
    }

    private func shouldPrintMPVLogMessage(prefix: String, level: String, text: String) -> Bool {
        switch level {
        case "fatal", "error", "warn":
            return true
        default:
            break
        }

        let normalizedPrefix = prefix.lowercased()
        if normalizedPrefix.contains("libass") || normalizedPrefix.contains("subtitle") || normalizedPrefix.hasPrefix("sub") {
            return true
        }

        let normalizedText = text.lowercased()
        let diagnosticKeywords = [
            "libass",
            "fontselect",
            "font provider",
            "glyph",
            "subtitle",
            "shader",
            "pipeline",
            "spir-v",
        ]
        return diagnosticKeywords.contains { normalizedText.contains($0) }
    }

    private func getDouble(_ name: String) -> Double {
        guard let mpv else { return 0.0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    private func getInt64(_ name: String) -> Int64? {
        guard let mpv else { return nil }
        var data = Int64()
        let status = mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        guard status >= 0 else { return nil }
        return data
    }

    private func getFlag(_ name: String) -> Bool? {
        guard let mpv else { return nil }
        var data = Int32()
        let status = mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        guard status >= 0 else { return nil }
        return data != 0
    }

    private func getString(_ name: String) -> String? {
        guard let mpv, let pointer = mpv_get_property_string(mpv, name) else {
            return nil
        }
        defer {
            mpv_free(UnsafeMutableRawPointer(pointer))
        }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    private func refreshDecoderModeAfterPlaybackRestart() {
        guard let activeHWDec = getString(MPVProperty.hwdecCurrent)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              activeHWDec.isEmpty == false else {
            mpvDebugLog("decoder mode remains initializing because hwdec-current is unavailable profile=\(activeProfileDescription)")
            setDecoderMode(.initializing)
            return
        }

        let decoderMode: MPVPlayerDecoderMode = activeHWDec.caseInsensitiveCompare("no") == .orderedSame
            ? .software
            : .hardware
        mpvDebugLog("decoder mode confirmed activeHWDec=\(activeHWDec) mode=\(decoderMode) profile=\(activeProfileDescription)")
        setDecoderMode(decoderMode)
    }

    private func logVideoColorParameters() {
        let inputProperties = [
            "video-params/pixelformat",
            "video-params/colormatrix",
            "video-params/colorlevels",
            "video-params/primaries",
            "video-params/gamma",
            "video-params/sig-peak"
        ]
        let filterOutputProperties = [
            "video-out-params/pixelformat",
            "video-out-params/colormatrix",
            "video-out-params/colorlevels",
            "video-out-params/primaries",
            "video-out-params/gamma",
            "video-out-params/sig-peak"
        ]
        let targetProperties = [
            "video-target-params/pixelformat",
            "video-target-params/colormatrix",
            "video-target-params/colorlevels",
            "video-target-params/primaries",
            "video-target-params/gamma",
            "video-target-params/sig-peak"
        ]
        mpvDebugLog(
            "video color params input=[\(videoColorParameterDescription(inputProperties))] filters=[\(videoColorParameterDescription(filterOutputProperties))] target=[\(videoColorParameterDescription(targetProperties))]"
        )
    }

    private func videoColorParameterDescription(_ properties: [String]) -> String {
        properties.map { property in
            let name = property.split(separator: "/").last.map(String.init) ?? property
            return "\(name)=\(getString(property) ?? "unavailable")"
        }
        .joined(separator: " ")
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var data = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    }

    private func setFlag(_ name: String, _ flag: Bool) {
        guard let mpv else { return }
        var data: Int32 = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    private var subtitleStylePropertyNames: [String] {
        [
            MPVProperty.subtitleFontSize,
            MPVProperty.subtitleBold,
            MPVProperty.subtitleColor,
            MPVProperty.subtitleOutlineSize,
            MPVProperty.subtitleOutlineColor,
            MPVProperty.subtitleShadowOffset,
            MPVProperty.subtitleBackColor,
            MPVProperty.subtitleBorderStyle,
            MPVProperty.subtitleMarginY,
        ]
    }

    private func decimalString(_ value: Any?, fallback: Double) -> String {
        let number = (value as? NSNumber)?.doubleValue ?? fallback
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), number.isFinite ? number : fallback)
    }

    private func subtitleMarginYString(_ bottomOffset: Any?) -> String {
        let offset = (bottomOffset as? NSNumber)?.doubleValue ?? 0
        guard offset.isFinite else { return "34" }
        return String(max(0, 34 + Int(offset.rounded())))
    }

    @discardableResult
    private func applySubtitleStyleMode(usesOriginalStyle: Bool) -> Bool {
        let override = usesOriginalStyle ? "no" : "strip"
        let status = command("set", args: [MPVProperty.subtitleASSOverride, override], checkForErrors: false)
        mpvDebugLog("subtitle style mode original=\(usesOriginalStyle) assOverride=\(override) status=\(status)")
        guard status >= 0 else { return false }
        if usesOriginalStyle == false, applyUserSubtitleStyleProperties() == false {
            return false
        }
        return true
    }

    private func applyUserSubtitleStyleOptions(to handle: OpaquePointer) {
        for property in subtitleStylePropertyNames {
            guard let value = subtitleStyleValues[property] else { continue }
            checkError(
                mpv_set_option_string(handle, property, value),
                operation: "set_option \(property)=\(value)",
                notifyOnFailure: false
            )
        }
    }

    @discardableResult
    private func applyUserSubtitleStyleProperties() -> Bool {
        var success = true
        for property in subtitleStylePropertyNames {
            guard let value = subtitleStyleValues[property] else { continue }
            success = command("set", args: [property, value], checkForErrors: false) >= 0 && success
        }
        mpvDebugLog("subtitle user style applied values=\(subtitleStyleValues)")
        return success
    }

    private func subtitleTrackIDs() -> Set<Int64> {
        guard let count = getInt64("track-list/count"), count > 0 else { return [] }
        return Set((0..<Int(count)).compactMap { index in
            guard getString("track-list/\(index)/type") == "sub" else { return nil }
            return getInt64("track-list/\(index)/id")
        })
    }

    private func externalSubtitleTrackID(
        source: String,
        urlString: String,
        preferringIDsNotIn previousIDs: Set<Int64>
    ) -> Int64? {
        guard let count = getInt64("track-list/count"), count > 0 else { return nil }
        let expectedSources = Set([canonicalExternalSubtitleSource(source), canonicalExternalSubtitleSource(urlString)])
        var matches: [Int64] = []
        for index in 0..<Int(count) {
            guard getString("track-list/\(index)/type") == "sub",
                  let trackID = getInt64("track-list/\(index)/id"),
                  let filename = getString("track-list/\(index)/external-filename"),
                  expectedSources.contains(canonicalExternalSubtitleSource(filename)) else {
                continue
            }
            matches.append(trackID)
        }
        return matches.first(where: { previousIDs.contains($0) == false }) ?? matches.first
    }

    private func canonicalExternalSubtitleSource(_ source: String) -> String {
        guard let url = URL(string: source) else {
            return URL(fileURLWithPath: source).standardizedFileURL.path
        }
        return url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    private func readMediaTracks(mediaType requestedType: String?) -> [[String: Any]] {
        guard let count = getInt64("track-list/count"), count > 0 else {
            return []
        }

        var tracks: [[String: Any]] = []
        for index in 0..<Int(count) {
            guard let mpvType = getString("track-list/\(index)/type") else {
                continue
            }
            if let requestedType, requestedType != mpvType {
                continue
            }
            guard let trackID = getInt64("track-list/\(index)/id") else {
                continue
            }

            let title = getString("track-list/\(index)/title")
            let languageCode = getString("track-list/\(index)/lang")
            let codec = getString("track-list/\(index)/codec")
            let name = mediaTrackName(
                id: trackID,
                mpvType: mpvType,
                title: title,
                languageCode: languageCode,
                codec: codec
            )
            let selected = getFlag("track-list/\(index)/selected") ?? false
            let bitRate = getInt64("track-list/\(index)/demux-bitrate")
                ?? getInt64("track-list/\(index)/bitrate")
                ?? 0

            var track: [String: Any] = [
                "trackID": NSNumber(value: Int32(clamping: trackID)),
                "subtitleID": "mpv-\(mpvType)-\(trackID)",
                "name": name,
                "mediaType": avMediaTypeRawValue(for: mpvType),
                "mpvType": mpvType,
                "codec": codec ?? "",
                "isEnabled": NSNumber(value: selected),
                "isImageSubtitle": NSNumber(value: isImageSubtitleCodec(codec)),
                "nominalFrameRate": NSNumber(value: 0),
                "bitRate": NSNumber(value: bitRate),
                "bitDepth": NSNumber(value: 0),
                "rotation": NSNumber(value: 0),
            ]
            if let languageCode {
                track["languageCode"] = languageCode
            }
            tracks.append(track)
        }
        return tracks
    }

    private func mediaTrackName(
        id: Int64,
        mpvType: String,
        title: String?,
        languageCode: String?,
        codec: String?
    ) -> String {
        let kind: String
        switch mpvType {
        case "video":
            kind = "Video"
        case "audio":
            kind = "Audio"
        case "sub":
            kind = "Subtitle"
        default:
            kind = mpvType.capitalized
        }

        let details = [title, languageCode, codec]
            .compactMap { value -> String? in
                guard let value,
                      value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    return nil
                }
                return value
            }

        if details.isEmpty {
            return "\(kind) \(id)"
        }
        return "\(kind) \(id) · \(details.joined(separator: " · "))"
    }

    private func avMediaTypeRawValue(for mpvType: String) -> String {
        switch mpvType {
        case "video":
            return AVMediaType.video.rawValue
        case "audio":
            return AVMediaType.audio.rawValue
        case "sub":
            return AVMediaType.subtitle.rawValue
        default:
            return mpvType
        }
    }

    private func mpvSelectionProperty(for mediaType: String) -> String? {
        switch mediaType {
        case "video":
            return MPVProperty.videoID
        case "audio":
            return MPVProperty.audioID
        case "sub":
            return MPVProperty.subtitleID
        default:
            return nil
        }
    }

    private func isImageSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else {
            return false
        }
        return codec.contains("pgs")
            || codec.contains("hdmv")
            || codec.contains("dvd_subtitle")
            || codec.contains("dvb_subtitle")
            || codec.contains("xsub")
    }

    @discardableResult
    private func command(
        _ command: String,
        args: [String?] = [],
        handle: OpaquePointer? = nil,
        checkForErrors: Bool = true
    ) -> Int32 {
        guard let mpv = handle ?? self.mpv else { return MPV_ERROR_UNINITIALIZED.rawValue }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }

        mpvDebugLog("command \(command) argCount=\(args.count)")
        let returnValue = mpv_command(mpv, &cargs)
        if checkForErrors {
            checkError(returnValue, operation: "command \(command)")
        }
        mpvDebugLog("command \(command) status=\(returnValue)")
        return returnValue
    }

    private func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        var stringArgs = args
        stringArgs.insert(command, at: 0)
        stringArgs.append(nil)
        return stringArgs
    }

    private func makeMPVHTTPHeaderFields() -> (fields: [String], skippedAuthHeaders: Int) {
        var fields: [String] = []
        var skippedAuthHeaders = 0
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanValue = value
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleanKey.isEmpty == false, cleanValue.isEmpty == false else { continue }
            if isMPVAuthorizationHeader(cleanKey) {
                skippedAuthHeaders += 1
                continue
            }
            fields.append("\(cleanKey): \(cleanValue)")
        }
        return (fields, skippedAuthHeaders)
    }

    private func isMPVAuthorizationHeader(_ key: String) -> Bool {
        key.caseInsensitiveCompare("Authorization") == .orderedSame
            || key.caseInsensitiveCompare("X-Emby-Authorization") == .orderedSame
    }

    @discardableResult
    private func checkError(_ status: CInt, operation: String? = nil, notifyOnFailure: Bool = true) -> Bool {
        if status < 0 {
            #if DEBUG
            let name = operation ?? "unknown"
            let message = String(cString: mpv_error_string(status))
            mpvDebugLog("api error operation=\(name) status=\(status) message=\(message)")
            #endif
            if notifyOnFailure {
                notifyState(.error)
            }
            return false
        }
        return true
    }

    private func performOnMPVQueueSync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private func redactedURLDescription(_ url: URL?) -> String {
        guard let url else { return "nil" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItemCount = components?.queryItems?.count ?? 0
        components?.query = nil
        return "\(components?.string ?? url.absoluteString) queryItems=\(queryItemCount)"
    }

    private var activeProfileDescription: String {
        guard setupProfiles.indices.contains(activeSetupProfileIndex) else {
            return "none"
        }
        return setupProfiles[activeSetupProfileIndex].name
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private func mpvDebugLog(_ message: String) {
        #if DEBUG
        print("MPVPlayerView[\(ObjectIdentifier(self))] \(message)")
        #endif
    }

    private func notifyState(_ state: MPVPlayerState) {
        notifyOnMain {
            NotificationCenter.default.post(
                name: MPVPlayerKitNotification.didChangeState,
                object: self,
                userInfo: [MPVPlayerKitNotificationKey.state: state.rawValue]
            )
        }
    }

    private func setDecoderMode(_ decoderMode: MPVPlayerDecoderMode) {
        notifyOnMain {
            NotificationCenter.default.post(
                name: MPVPlayerKitNotification.didUpdateDecoderMode,
                object: self,
                userInfo: [MPVPlayerKitNotificationKey.decoderMode: decoderMode.rawValue]
            )
        }
    }

    private func notifyTime(currentTime: TimeInterval, duration: TimeInterval) {
        notifyOnMain {
            NotificationCenter.default.post(
                name: MPVPlayerKitNotification.didUpdateTime,
                object: self,
                userInfo: [
                    MPVPlayerKitNotificationKey.currentTime: currentTime,
                    MPVPlayerKitNotificationKey.duration: duration,
                ]
            )
        }
    }

    private func notifyBufferingProgress(_ bufferingProgress: Int) {
        NotificationCenter.default.post(
            name: MPVPlayerKitNotification.didUpdateBufferingProgress,
            object: self,
            userInfo: [MPVPlayerKitNotificationKey.bufferingProgress: bufferingProgress]
        )
    }

    private func notifyOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }
}

private final class MPVPlayerMetalLayer: CAMetalLayer {
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
