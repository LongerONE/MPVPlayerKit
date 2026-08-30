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

    func setupMPV() {
        guard let url else {
            mpvDebugLog("setupMPV failed missing url")
            failSetup()
            return
        }

        activeSetupProfileIndex = 0
        // Playback setup runs on `queue`, so UIKit geometry must be sampled on
        // the main thread before it is included in diagnostics. Reading
        // `UIView.bounds` here triggers Main Thread Checker and can terminate a
        // debug session while libmpv is starting.
        let boundsSnapshot = currentViewBoundsSnapshot()
        mpvDebugLog("setupMPV begin url=\(redactedURLDescription(url)) bounds=\(boundsSnapshot) headers=\(headers.count) profiles=\(setupProfiles.map(\.name).joined(separator: ","))")

        while true {
            prepareProfilesForNextRenderer()
            guard activeSetupProfileIndex < setupProfiles.count else { break }
            let profile = setupProfiles[activeSetupProfileIndex]
            if setupMPV(url: url, profile: profile) {
                return
            }
            activeSetupProfileIndex += 1
            pictureInPictureRendererRuntimeState.setActiveProfileIndex(
                activeSetupProfileIndex
            )
        }

        mpvDebugLog("setupMPV exhausted all profiles")
        failSetup()
    }

    func prepareProfilesForNextRenderer() {
        // Reserve the renderer slot before reading options. Screen changes
        // after this point become pending instead of mutating CAMetalLayer
        // during profile or handle construction.
        prepareColorOutputForRendererSetup()
        setupProfiles = makeSetupProfiles()
        pictureInPictureRendererRuntimeState.store(
            profiles: setupProfiles.map(
                MPVPictureInPictureRendererInvariantSnapshot.SetupProfile.init
            ),
            activeProfileIndex: activeSetupProfileIndex
        )
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

    var metalVideoOutputOptions: [(String, String)] {
        let outputMode = MPVColorMappingPolicy.outputMode(
            usesExtendedDynamicRangeOutput: usesExtendedDynamicRangeOutput
        )
        let colorOptions = MPVColorMappingPolicy.options(for: outputMode)
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
        [("deband", debandEnabled ? "yes" : "no")]
    }

    nonisolated var cacheOptions: [(String, String)] {
        [
            (MPVProperty.cache, cacheConfiguration.isEnabled ? "yes" : "no"),
            (
                MPVProperty.cacheSeconds,
                String(
                    format: "%.3f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    cacheConfiguration.duration
                )
            ),
            ("cache-on-disk", "no"),
            ("demuxer-max-bytes", Self.demuxerMaxBytes),
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
                    configuration.duration
                )
            ),
            ("cache-on-disk", "no"),
        ]
        options.forEach { option in
            let status = command("set", args: [option.0, option.1], checkForErrors: false)
            mpvDebugLog("cache option updated name=\(option.0) status=\(status)")
        }
        mpvDebugLog(
            "cache options updated enabled=\(configuration.isEnabled) seconds=\(configuration.duration)"
        )
        logEffectiveCacheSettings(reason: "runtime")
    }

    nonisolated func applyVideoRenderProperties() {
        videoRenderOptions.forEach { option in
            _ = command("set", args: [option.0, option.1], checkForErrors: false)
        }
        mpvDebugLog("video render options updated deband=\(debandEnabled)")
        logEffectiveVideoSettings(reason: "render-runtime")
    }

    nonisolated func logEffectiveVideoSettings(reason: String) {
        let propertyNames = [
            "scale",
            "cscale",
            "dscale",
            "scaler-resizes-only",
            "scale-antiring",
            "cscale-antiring",
            "dscale-antiring",
            "correct-downscaling",
            "linear-downscaling",
            "sigmoid-upscaling",
            "dither",
            "dither-depth",
            "hdr-compute-peak",
            "allow-delayed-peak-detect",
            "interpolation",
            "deband",
        ]
        let properties = propertyNames.map { name in
            "\(name)=\(getString(name) ?? "<unavailable>")"
        }
        .joined(separator: " ")
        mpvDebugLog(
            "video settings effective reason=\(reason) requestedQuality=\(videoQualityPreset) requestedDeband=\(debandEnabled) properties=[\(properties)]"
        )
    }

    func setupMPV(url: URL, profile: MPVSetupProfile) -> Bool {
        mpvDebugLog("setupMPV profile begin name=\(profile.name) index=\(activeSetupProfileIndex + 1)/\(setupProfiles.count)")
        mpvDebugLog(
            "setupMPV profile options name=\(profile.name) count=\(profile.options.count)"
        )
        performOnMPVQueueSync {
            lastMPVTimeSnapshot = nil
            currentSubtitleUsesOriginalStyle = false
            loadedExternalSubtitleIDs.removeAll(keepingCapacity: true)
            pendingExternalSubtitleLoad = nil
            canceledExternalSubtitleCommands.removeAll(keepingCapacity: true)
            pendingSeekCommands.removeAll(keepingCapacity: true)
            activeExternalSubtitleActivation = nil
            committedSubtitleSelection = nil
            nextMPVCommandUserdata = 1
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

        let loadURL = url.absoluteString

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
        logEffectiveCacheSettings(reason: "setup")
        logEffectiveSubtitleConfiguration()
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.pausedForCache, MPV_FORMAT_FLAG),
            operation: "observe paused-for-cache",
            notifyOnFailure: false
        )
        checkError(
            mpv_observe_property(mpv, 0, MPVProperty.demuxerCacheTime, MPV_FORMAT_DOUBLE),
            operation: "observe demuxer-cache-time",
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
        let loadStatus = command("loadfile", args: [loadURL, "replace"], checkForErrors: false)
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

    func ensureMPVReady() -> Bool {
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

    private func currentViewBoundsSnapshot() -> CGRect {
        guard Thread.isMainThread else { return .zero }
        return bounds
    }

    func failSetup() {
        setSetupFailed(true)
        destroyMPVHandle(reason: "setup-failed")
        pictureInPictureRendererRuntimeState.reset()
        notifyState(.error)
    }

    func destroyMPVHandle(reason: String, sendStopCommand: Bool = true) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.stopPictureInPictureForPlayerTeardown()
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.stopPictureInPictureForPlayerTeardown()
                }
            }
        }

        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            destroyMPVHandleOnMPVQueue(reason: reason, sendStopCommand: sendStopCommand)
        } else {
            // mpv_terminate_destroy may wait for decoder/rendering work. The
            // caller must not synchronously wait for the MPV queue here.
            queue.async { [self] in
                destroyMPVHandleOnMPVQueue(reason: reason, sendStopCommand: sendStopCommand)
            }
        }
    }

    private func destroyMPVHandleOnMPVQueue(reason: String, sendStopCommand: Bool) {
        MPVSystemPlaybackCoordinator.shared.deactivate(playerView: self)
        setDecoderMode(.initializing)
        stopTimeTimer()
        clearMediaTracksCache()
        pendingMetalLayerGeometry = nil
        isMetalGeometryTransitionInProgress = false
        lastLoggedSubtitleText = ""
        hasLoggedSubtitleTextEvent = false
        resetGeometryTransitionAnimation()
        notifyOnMain {
            self.updatePictureInPictureVideoDisplaySize(.zero)
        }
        performOnMPVQueueSync {
            let pendingRequestIDs = pendingExternalSubtitleLoad?.requestIDs ?? []
            if let mpv, let pending = pendingExternalSubtitleLoad {
                mpv_abort_async_command(mpv, pending.userdata)
            }
            pendingExternalSubtitleLoad = nil
            let pendingSeekRequests = Array(pendingSeekCommands.values)
            pendingSeekCommands.removeAll(keepingCapacity: true)
            if pendingSeekRequests.isEmpty == false, mpv != nil {
                publishTime()
            }
            pendingSeekRequests.forEach {
                notifySeekCompletion(
                    request: $0.request,
                    success: false,
                    error: MPV_ERROR_UNINITIALIZED.rawValue
                )
            }
            loadedExternalSubtitleIDs.removeAll(keepingCapacity: true)
            canceledExternalSubtitleCommands.removeAll(keepingCapacity: true)
            activeExternalSubtitleActivation = nil
            committedSubtitleSelection = nil
            nextMPVCommandUserdata = 1
            subtitleSelectionEpoch = 0
            currentSubtitleUsesOriginalStyle = false
            pendingRequestIDs.forEach { notifySubtitleLoad(requestID: $0, success: false) }
            guard let mpv else {
                lastMPVTimeSnapshot = nil
                markColorOutputRendererStopped()
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
            markColorOutputRendererStopped()
            mpvDebugLog("destroyMPVHandle stage=terminate-end reason=\(reason)")
            lastMPVTimeSnapshot = nil
        }
    }

}
