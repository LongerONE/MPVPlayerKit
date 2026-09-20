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

extension MPVPlayerView {
    /// Keep decoded VideoToolbox surfaces on the GPU path first. The copy
    /// profile remains available because some libmpv/MoltenVK combinations
    /// cannot safely import the decoder surface for every HEVC/Dolby Vision
    /// stream.
    nonisolated static let deviceHardwareDecodeMethod = "videotoolbox"
    nonisolated static let deviceCopyHardwareDecodeMethod = "videotoolbox-copy"
    /// A hard safety cap for demuxer packet metadata. `cache-secs` is a time
    /// target and can still represent a large byte range for high-bitrate
    /// media, so keep a bounded memory budget as well.
    nonisolated static let demuxerMaxBytes = "256MiB"
    /// Do not retain an additional unbounded-looking past range while the
    /// player is already using a forward cache.
    nonisolated static let demuxerMaxBackBytes = "0"
    /// libmpv `MPV_ERROR_OPTION_NOT_FOUND`
    nonisolated static let mpvErrorOptionNotFound: CInt = -5
    /// Simulator / power-saving tuning knobs that may be absent in a given MPVKit build.
    nonisolated static let optionalSetupOptionNames: Set<String> = [
        "video-max-x",
        "video-max-y",
        "gpu-dumb-mode",
        "vd-lavc-threads",
        "demuxer-hysteresis-secs",
        "cache-on-disk",
        "vf",
    ]
    /// Portable resolution cap for simulator (video-max-x/y unavailable in MPVKit 1.0.0).
    nonisolated static let simulatorResolutionLimitFilter =
        "scale=1280:720"
    /// Preferred runtime vf candidates when option-stage `vf` cannot be applied.
    nonisolated static let simulatorResolutionLimitCandidates = [
        "lavfi=[scale=w=min(1280,iw):h=min(720,ih)]",
        "scale=w=min(1280\\,iw):h=min(720\\,ih)",
        "scale=1280:720",
    ]

    nonisolated static func safeDecodeOptions(
        hardwareDecodeMethod: String
    ) -> [(String, String)] {
        let directRendering = hardwareDecodeMethod == deviceHardwareDecodeMethod ? "auto" : "no"
        return [
            ("hwdec", hardwareDecodeMethod),
            // Direct VideoToolbox decoding avoids a 4K frame copy. The copy
            // fallback explicitly disables direct rendering to keep the
            // staging-buffer lifetime safe on older devices/builds.
            ("vd-lavc-dr", directRendering),
        ]
    }

    nonisolated func setupMPV() {
        guard let url else {
            mpvDebugLog("setupMPV failed missing url")
            failSetup()
            return
        }

        setActiveSetupProfileIndex(0)
        // Playback setup runs on `queue`, so UIKit geometry must be sampled on
        // the main thread before it is included in diagnostics. Reading
        // `UIView.bounds` here triggers Main Thread Checker and can terminate a
        // debug session while libmpv is starting.
        let boundsSnapshot = currentViewBoundsSnapshot()
        mpvDebugLog("setupMPV begin url=\(redactedURLDescription(url)) bounds=\(boundsSnapshot) headers=\(headers.count)")
        // Allocate the renderer surface before libmpv receives `wid`. The
        // surface remains fixed while UIKit animates portrait/landscape.
        prepareStableMetalCanvasForRendererSetup()

        while true {
            prepareProfilesForNextRenderer()
            let profile = activeSetupProfileSnapshot()
            guard profile.index < profile.count,
                  let currentProfile = setupProfile(at: profile.index) else { break }
            if setupMPV(url: url, profile: currentProfile) {
                return
            }
            setActiveSetupProfileIndex(profile.index + 1)
            pictureInPictureRendererRuntimeState.setActiveProfileIndex(
                profile.index + 1
            )
        }

        mpvDebugLog("setupMPV exhausted all profiles")
        failSetup()
    }

    nonisolated func prepareProfilesForNextRenderer() {
        // Reserve the renderer slot before reading options. Screen changes
        // after this point become pending instead of mutating CAMetalLayer
        // during profile or handle construction.
        prepareColorOutputForRendererSetup()
        let profiles = makeSetupProfiles()
        let index = activeSetupProfileSnapshot().index
        replaceSetupProfiles(profiles, activeIndex: index)
        pictureInPictureRendererRuntimeState.store(
            profiles: profiles.map(
                MPVPictureInPictureRendererInvariantSnapshot.SetupProfile.init
            ),
            activeProfileIndex: index
        )
    }

    nonisolated func makeSetupProfiles() -> [MPVSetupProfile] {
        #if targetEnvironment(simulator)
        let hardwareDecode = "no"
        #else
        let hardwareDecode = Self.deviceHardwareDecodeMethod
        #endif

        let softwareDecodeOptions = Self.safeDecodeOptions(
            hardwareDecodeMethod: "no"
        )

        let softwareProfile = MPVSetupProfile(
            name: "metal-software",
            options: cacheOptions + metalVideoOutputOptions + softwareDecodeOptions
        )

        guard forceSoftwareDecode == false, hardwareDecode != "no" else {
            return [softwareProfile]
        }

        let directHardwareProfile = MPVSetupProfile(
            name: "metal-videotoolbox",
            options: cacheOptions + metalVideoOutputOptions + Self.safeDecodeOptions(
                hardwareDecodeMethod: hardwareDecode
            )
        )
        let copyHardwareProfile = MPVSetupProfile(
            name: "metal-videotoolbox-copy",
            options: cacheOptions + metalVideoOutputOptions + Self.safeDecodeOptions(
                hardwareDecodeMethod: Self.deviceCopyHardwareDecodeMethod
            )
        )

        return [
            directHardwareProfile,
            copyHardwareProfile,
            softwareProfile,
        ]
    }

    nonisolated var metalVideoOutputOptions: [(String, String)] {
        colorOutputStateLock.lock()
        let outputMode = colorOutputState.currentMode
        colorOutputStateLock.unlock()
        let colorOptions = MPVColorMappingPolicy.options(for: outputMode)
        #if targetEnvironment(simulator)
        // 模拟器仅有软件解码；4K/HEVC 帧经 libplacebo PBO 上传时，
        // MoltenVK 的 host-visible MTLBuffer 分配会撞上 XPC shmem 限制。
        // MPVKit 1.0.0 无 video-max-x/y（-5），改用标准 vf scale 限流，
        // setup 阶段 applySimulatorDecoderResolutionCap 会再兜底尝试。
        return colorOptions + [
            ("gpu-dumb-mode", "yes"),
            ("vf", Self.simulatorResolutionLimitFilter),
            ("vd-lavc-threads", "2"),
        ] + MPVVideoQualityPreset.powerSaving.options + videoRenderOptions
        #else
        return colorOptions + videoQualityPreset.options + videoRenderOptions
        #endif
    }

    nonisolated func applyVideoQualityProperties(_ preset: MPVVideoQualityPreset) {
        preset.options.forEach { option in
            let status = command("set", args: [option.0, option.1], checkForErrors: false)
            if status < 0 {
                mpvDebugLog(
                    "video quality option failed name=\(option.0) value=\(option.1) status=\(status)"
                )
            }
        }
        mpvDebugLog("video quality updated preset=\(preset) options=\(preset.options)")
        recordDiagnosticSnapshot("画质设置变化")
    }

    nonisolated var videoRenderOptions: [(String, String)] {
        [("deband", effectiveDebandEnabled ? "yes" : "no")]
    }

    nonisolated var effectiveDebandEnabled: Bool {
        #if targetEnvironment(simulator)
        // 模拟器固定走省电渲染路径；额外 deband pass 会放大 vo_thread 内存压力。
        return false
        #else
        // Keep the power-saving tier free of the optional debanding pass.
        return debandEnabled && videoQualityPreset != .powerSaving
        #endif
    }

    nonisolated var cacheOptions: [(String, String)] {
        #if targetEnvironment(simulator)
        // 模拟器内存与 XPC shmem 更紧，前向缓存压到 64MiB；大文件再压到 32MiB 更稳。
        let demuxerMaxBytes = "32MiB"
        #else
        let demuxerMaxBytes = Self.demuxerMaxBytes
        #endif
        return [
            (MPVProperty.cache, cacheConfiguration.isEnabled ? "yes" : "no"),
            // 禁用缓存时下发 0，避免 cache=no 仍携带正数 duration。
            (
                MPVProperty.cacheSeconds,
                String(
                    format: "%.3f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    cacheConfiguration.isEnabled ? cacheConfiguration.duration : 0
                )
            ),
            ("demuxer-hysteresis-secs", String(cacheConfiguration.demuxerHysteresisSeconds)),
            ("cache-on-disk", "no"),
            ("demuxer-max-bytes", demuxerMaxBytes),
            ("demuxer-max-back-bytes", Self.demuxerMaxBackBytes),
        ]
    }

    nonisolated func applyCacheConfiguration(_ configuration: MPVCacheConfiguration) {
        let options = [
            (MPVProperty.cache, configuration.isEnabled ? "yes" : "no"),
            (
                MPVProperty.cacheSeconds,
                String(
                    format: "%.3f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    configuration.isEnabled ? configuration.duration : 0
                )
            ),
            ("demuxer-hysteresis-secs", String(configuration.demuxerHysteresisSeconds)),
            ("cache-on-disk", "no"),
        ]
        options.forEach { option in
            let status = command("set", args: [option.0, option.1], checkForErrors: false)
            mpvDebugLog("cache option updated name=\(option.0) status=\(status)")
        }
        mpvDebugLog(
            "cache options updated enabled=\(configuration.isEnabled) seconds=\(configuration.duration)"
        )
        recordDiagnosticSnapshot("缓存设置变化")
    }

    nonisolated func applyVideoRenderProperties() {
        videoRenderOptions.forEach { option in
            _ = command("set", args: [option.0, option.1], checkForErrors: false)
        }
        mpvDebugLog(
            "video render options updated deband=\(effectiveDebandEnabled) requested=\(debandEnabled)"
        )
        recordDiagnosticSnapshot("渲染设置变化")
    }

    /// Simulator-only fallback when `video-max-x/y` is unavailable.
    /// Caps decoder output via vf scale so software decode stays inside MTLSimDriver limits.
    private nonisolated func applySimulatorDecoderResolutionCap(mpv: OpaquePointer, profileName: String) {
        #if targetEnvironment(simulator)
        let candidates = Self.simulatorResolutionLimitCandidates
        for filter in candidates {
            let status = mpv_set_option_string(mpv, "vf", filter)
            if status >= 0 {
                mpvDebugLog(
                    "setupMPV simulator vf cap applied filter=\(filter) profile=\(profileName)"
                )
                recordDiagnosticEvent(
                    "模拟器分辨率回退",
                    fields: ["配置": profileName, "滤镜": filter]
                )
                return
            }
            mpvDebugLog(
                "setupMPV simulator vf cap failed filter=\(filter) status=\(status) profile=\(profileName)"
            )
        }
        // 最后再限制 demuxer 内存，降低 OOM/崩溃概率（不替代分辨率上限）。
        _ = mpv_set_option_string(mpv, "demuxer-max-bytes", "32MiB")
        recordDiagnosticEvent(
            "模拟器分辨率回退失败",
            fields: ["配置": profileName]
        )
        #endif
    }

    nonisolated func setupMPV(url: URL, profile: MPVSetupProfile) -> Bool {
        var didSetup = false
        performOnMPVQueueSync {
            didSetup = setupMPVOnMPVQueue(url: url, profile: profile)
        }
        return didSetup
    }

    private nonisolated func setupMPVOnMPVQueue(url: URL, profile: MPVSetupProfile) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let playbackUpdateSourceSession = currentBufferingSessionGeneration()
        let profileIndex = activeSetupProfileSnapshot().index
        recordDiagnosticEvent("尝试解码配置", fields: ["配置": profile.name, "序号": String(profileIndex)])
        mpvDebugLog("setupMPV profile begin name=\(profile.name) index=\(profileIndex + 1)")
        mpvDebugLog(
            "setupMPV profile options name=\(profile.name) count=\(profile.options.count)"
        )
        resetBufferingStateOnMPVQueue(reason: "setup")
        lastMPVTimeSnapshot = nil
        currentSubtitleUsesOriginalStyle = false
        clearSubtitleTextCache()
        loadedExternalSubtitleIDs.removeAll(keepingCapacity: true)
        pendingExternalSubtitleLoad = nil
        canceledExternalSubtitleCommands.removeAll(keepingCapacity: true)
        pendingSeekCommands.removeAll(keepingCapacity: true)
        activeExternalSubtitleActivation = nil
        committedSubtitleSelection = nil
        nextMPVCommandUserdata = 1
        subtitleSelectionEpoch = 0
        mpv = mpv_create()
        guard let mpv else {
            mpvDebugLog("setupMPV mpv_create returned nil profile=\(profile.name)")
            return false
        }
        bindMPVPlaybackUpdateSourceSession(playbackUpdateSourceSession)
        diagnosticProbe?.bindStaticMPVFieldCache(to: mpv)
        mpvDebugLog("setupMPV created handle=\(mpv)")

        let loadURL = url.absoluteString

        // 原始 mpv 日志可能包含媒体地址或字幕正文；只使用白名单结构化诊断。
        checkError(mpv_request_log_messages(mpv, "no"), operation: "request_log_messages", notifyOnFailure: false)

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
            let status = mpv_set_option_string(mpv, option.0, option.1)
            if checkError(
                status,
                operation: "set_option \(option.0)=\(option.1)",
                notifyOnFailure: false
            ) {
                continue
            }
            // MPVKit / libmpv builds may not expose every tuning option
            // (e.g. video-max-x → MPV_ERROR_OPTION_NOT_FOUND = -5 on iOS 27 / iPhone Duo).
            // Missing optional options must not abort the whole profile.
            if Self.optionalSetupOptionNames.contains(option.0) || status == Self.mpvErrorOptionNotFound {
                mpvDebugLog(
                    "setupMPV optional option skipped name=\(option.0) value=\(option.1) status=\(status)"
                )
                recordDiagnosticEvent(
                    "跳过可选选项",
                    fields: ["选项": option.0, "错误码": String(status), "配置": profile.name]
                )
                continue
            }
            destroyMPVHandle(reason: "profile-\(profile.name)-option-\(option.0)-failed", sendStopCommand: false)
            return false
        }
        // Simulator: large software-decoded frames can crash MoltenVK/XPC
        // (vkAllocateMemory / _xpc_api_misuse) when video-max-* is missing.
        applySimulatorDecoderResolutionCap(mpv: mpv, profileName: profile.name)
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
        #if targetEnvironment(simulator)
        // 初始化后再次确保限流生效（option 阶段若 vf 被跳过，这里用 runtime property 补上）。
        var vfStatus: CInt = -1
        for filter in Self.simulatorResolutionLimitCandidates {
            vfStatus = command("set", args: ["vf", filter], checkForErrors: false)
            mpvDebugLog("setupMPV simulator vf runtime apply status=\(vfStatus) filter=\(filter)")
            if vfStatus >= 0 {
                recordDiagnosticEvent(
                    "模拟器限流生效",
                    fields: ["滤镜": filter, "配置": profile.name]
                )
                break
            }
        }
        if vfStatus < 0 {
            recordDiagnosticEvent(
                "模拟器限流失败",
                fields: ["错误码": String(vfStatus), "配置": profile.name]
            )
        }
        #endif
        // Some libmpv builds accept subtitle styling only as pre-initialization
        // options, but do not apply the font size to a newly added text track.
        // Reapply the cached values as runtime properties so the first SRT load
        // uses the same style as a later settings change.
        if applyUserSubtitleStyleProperties() == false {
            mpvDebugLog("setupMPV could not apply runtime subtitle style profile=\(profile.name)")
        }
        applyContentModeOnMPVQueue(currentContentModeSnapshotForRendererSetup())
        mpvDebugLog("setupMPV initialized profile=\(profile.name)")
        recordDiagnosticSnapshot("渲染初始化")
        _ = mpv_observe_property(mpv, 0, MPVProperty.hwdecCurrent, MPV_FORMAT_STRING)
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.pausedForCache, MPV_FORMAT_FLAG),
            operation: "observe paused-for-cache",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.cacheBufferingState, MPV_FORMAT_DOUBLE),
            operation: "observe cache-buffering-state",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.coreIdle, MPV_FORMAT_FLAG),
            operation: "observe core-idle",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.pause, MPV_FORMAT_FLAG),
            operation: "observe pause",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.idleActive, MPV_FORMAT_FLAG),
            operation: "observe idle-active",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.eofReached, MPV_FORMAT_FLAG),
            operation: "observe eof-reached",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.seeking, MPV_FORMAT_FLAG),
            operation: "observe seeking",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.demuxerCacheTime, MPV_FORMAT_DOUBLE),
            operation: "observe demuxer-cache-time",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.videoOutputDisplayWidth, MPV_FORMAT_INT64),
            operation: "observe video-out-params/dw",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.videoOutputDisplayHeight, MPV_FORMAT_INT64),
            operation: "observe video-out-params/dh",
            notifyOnFailure: false
        )
        let wakeupContext = MPVWakeupContext(self)
        let wakeupUnmanaged = Unmanaged.passRetained(wakeupContext)
        wakeupContextTransfer = wakeupUnmanaged
        mpv_set_wakeup_callback(
            mpv,
            mpvPlayerWakeupCallback,
            wakeupUnmanaged.toOpaque()
        )
        mpvDebugLog("setupMPV wakeup callback installed profile=\(profile.name)")

        notifyState(.buffering)
        let loadStatus = command("loadfile", args: [loadURL, "replace"], checkForErrors: false)
        guard loadStatus >= 0 else {
            mpvDebugLog("setupMPV loadfile failed profile=\(profile.name) status=\(loadStatus)")
            destroyMPVHandle(reason: "profile-\(profile.name)-loadfile-failed", sendStopCommand: false)
            return false
        }
        mpvDebugLog("setupMPV profile ready name=\(profile.name)")
        return true
    }

    nonisolated func configureGPUShaderCache(for handle: OpaquePointer) {
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

    nonisolated func configureSystemSubtitleFont(for handle: OpaquePointer) {
        if let fontDirectory = systemSubtitleFontDirectory {
            checkError(
                mpv_set_option_string(handle, MPVProperty.subtitleFontProvider, "auto"),
                operation: "set_option sub-font-provider=auto",
                notifyOnFailure: false
            )
            checkError(
                mpv_set_option_string(handle, "sub-fonts-dir", fontDirectory),
                operation: "set_option sub-fonts-dir",
                notifyOnFailure: false
            )
        } else {
            mpvDebugLog("bundled subtitle font directory missing")
        }
        let fontName = subtitleFontName(isBold: false)
        checkError(
            mpv_set_option_string(handle, MPVProperty.subtitleFont, fontName),
            operation: "set_option sub-font=\(fontName)",
            notifyOnFailure: false
        )
        mpvDebugLog("subtitle font configured default=\(fontName)")
    }

    nonisolated func ensureMPVReady() -> Bool {
        if mpv != nil {
            return true
        }
        guard isStopped() == false, isSetupFailed() == false else {
            notifyState(.error)
            return false
        }
        setupMPV()
        return mpv != nil
    }

    private nonisolated func currentViewBoundsSnapshot() -> CGRect {
        guard Thread.isMainThread else { return .zero }
        return MainActor.assumeIsolated { bounds }
    }

    nonisolated func failSetup() {
        setSetupFailed(true)
        destroyMPVHandle(reason: "setup-failed")
        pictureInPictureRendererRuntimeState.reset()
        notifyState(.error)
    }
}
