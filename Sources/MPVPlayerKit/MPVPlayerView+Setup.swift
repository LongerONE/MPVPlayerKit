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

func mpvPlayerWakeupCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let playerView = Unmanaged<MPVPlayerView>.fromOpaque(context).takeUnretainedValue()
    playerView.readEvents()
}

extension MPVPlayerView {
    nonisolated static let deviceHardwareDecodeMethod = "videotoolbox-copy"

    nonisolated static func safeDecodeOptions(
        hardwareDecodeMethod: String
    ) -> [(String, String)] {
        [
            ("hwdec", hardwareDecodeMethod),
            // Vulkan enables decoder direct rendering by default. Keeping decoded
            // frames in ordinary system memory prevents MoltenVK from observing a
            // VideoToolbox/staging buffer deallocation before its command completes.
            ("vd-lavc-dr", "no"),
        ]
    }

    func setupMPV() {
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

    func makeSetupProfiles() -> [MPVSetupProfile] {
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
            options: metalVideoOutputOptions + softwareDecodeOptions
        )

        guard forceSoftwareDecode == false, hardwareDecode != "no" else {
            return [softwareProfile]
        }

        return [
            MPVSetupProfile(
                name: "metal-videotoolbox",
                options: metalVideoOutputOptions + Self.safeDecodeOptions(
                    hardwareDecodeMethod: hardwareDecode
                )
            ),
            softwareProfile,
        ]
    }

    var metalVideoOutputOptions: [(String, String)] {
        let colorOptions: [(String, String)]
        if usesExtendedDynamicRangeOutput && isDolbyVisionPlayback {
            colorOptions = Self.dolbyVisionEDRMetalVideoOutputOptions
        } else if usesExtendedDynamicRangeOutput {
            colorOptions = Self.edrMetalVideoOutputOptions
        } else {
            colorOptions = Self.sdrMetalVideoOutputOptions
        }
        #if targetEnvironment(simulator)
        return colorOptions + [
            ("gpu-dumb-mode", "yes"),
        ] + videoQualityPreset.options + videoRenderOptions
        #else
        return colorOptions + videoQualityPreset.options + videoRenderOptions
        #endif
    }

    nonisolated func applyVideoQualityProperties(_ preset: MPVVideoQualityPreset) {
        preset.options.forEach { option in
            _ = command("set", args: [option.0, option.1], checkForErrors: false)
        }
        mpvDebugLog("video quality updated preset=\(preset) options=\(preset.options)")
        logEffectiveVideoSettings(reason: "quality-runtime")
    }

    nonisolated var videoRenderOptions: [(String, String)] {
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

    nonisolated func applyVideoRenderProperties() {
        videoRenderOptions.forEach { option in
            _ = command("set", args: [option.0, option.1], checkForErrors: false)
        }
        mpvDebugLog(
            "video render options updated deband=\(debandEnabled) interpolationQuality=\(interpolationOptions.quality) tscale=\(interpolationOptions.temporalScaler.rawValue)"
        )
        logEffectiveVideoSettings(reason: "render-runtime")
    }

    nonisolated func logEffectiveVideoSettings(reason: String) {
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

    func setupMPV(url: URL, profile: MPVSetupProfile) -> Bool {
        mpvDebugLog("setupMPV profile begin name=\(profile.name) index=\(activeSetupProfileIndex + 1)/\(setupProfiles.count)")
        let profileDescription = profile.options
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: " ")
        mpvDebugLog(
            "setupMPV profile options name=\(profile.name) [\(profileDescription)]"
        )
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
        // Some libmpv builds accept subtitle styling only as pre-initialization
        // options, but do not apply the font size to a newly added text track.
        // Reapply the cached values as runtime properties so the first SRT load
        // uses the same style as a later settings change.
        if applyUserSubtitleStyleProperties() == false {
            mpvDebugLog("setupMPV could not apply runtime subtitle style profile=\(profile.name)")
        }
        applyContentMode(currentContentModeSnapshot())
        mpvDebugLog("setupMPV initialized profile=\(profile.name)")
        mpvDebugLog(
            "render diagnostics reason=setup "
                + renderingDiagnosticDescription()
        )
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
        mpv_set_wakeup_callback(
            mpv,
            mpvPlayerWakeupCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
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

    func configureGPUShaderCache(for handle: OpaquePointer) {
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

    func configureSystemSubtitleFont(for handle: OpaquePointer) {
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

    func ensureMPVReady() -> Bool {
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

    func failSetup() {
        setupFailed = true
        destroyMPVHandle(reason: "setup-failed")
        notifyState(.error)
    }

    func destroyMPVHandle(reason: String, sendStopCommand: Bool = true) {
        setDecoderMode(.initializing)
        stopTimeTimer()
        clearMediaTracksCache()
        pendingMetalLayerGeometry = nil
        isMetalGeometryTransitionInProgress = false
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
            mpvDebugLog("destroyMPVHandle stage=wakeup-cleared reason=\(reason)")
            self.mpv = nil
            mpvDebugLog("destroyMPVHandle stage=handle-detached reason=\(reason)")
            if sendStopCommand {
                let stopStatus = command("stop", handle: mpv, checkForErrors: false)
                mpvDebugLog("destroyMPVHandle stop command status=\(stopStatus)")
            }
            mpvDebugLog("destroyMPVHandle stage=terminate-begin reason=\(reason)")
            mpv_terminate_destroy(mpv)
            mpvDebugLog("destroyMPVHandle stage=terminate-end reason=\(reason)")
        }
    }

}
