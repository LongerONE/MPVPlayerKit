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
        refreshColorOutputForTargetScreen(reason: "play")
        let generation = nextPlaybackIntentGeneration()
        mpvDebugLog("play requested stopped=\(isStopped()) setupFailed=\(isSetupFailed())")
        guard isStopped() == false, isSetupFailed() == false else {
            notifyState(.error)
            return
        }

        // mpv_initialize and the first loadfile can perform decoder, GPU, and
        // network setup. Keep them off the main actor so the presenting view
        // remains responsive while playback becomes ready.
        queue.async { [weak self] in
            guard let self,
                  self.isPlaybackIntentCurrent(generation),
                  self.isStopped() == false,
                  self.isSetupFailed() == false
            else {
                return
            }

            guard self.ensureMPVReady(),
                  self.isPlaybackIntentCurrent(generation),
                  self.isStopped() == false,
                  self.isSetupFailed() == false,
                  self.mpv != nil
            else {
                self.notifyOnMain {
                    self.isPlaying = false
                }
                return
            }

            self.setFlag(MPVProperty.pause, false)
            self.startTimeTimer()
            let state: MPVPlayerState = self.hasReportedReadyToPlay ? .bufferFinished : .buffering
            self.notifyOnMain {
                guard self.isPlaybackIntentCurrent(generation), self.isStopped() == false else {
                    return
                }
                self.isPlaying = true
                self.notifyState(state)
                MPVSystemPlaybackCoordinator.shared.activate(playerView: self)
            }
        }
    }

    @objc public func pause() {
        let generation = nextPlaybackIntentGeneration()
        mpvDebugLog("pause")
        queue.async { [weak self] in
            guard let self,
                  self.isPlaybackIntentCurrent(generation),
                  self.mpv != nil
            else {
                return
            }
            self.setFlag(MPVProperty.pause, true)
            self.stopTimeTimer()
            self.notifyOnMain {
                guard self.isPlaybackIntentCurrent(generation) else { return }
                self.isPlaying = false
                self.notifyState(.paused)
                MPVSystemPlaybackCoordinator.shared.publish(playerView: self)
            }
        }
    }

    @objc public func stop() {
        _ = nextPlaybackIntentGeneration()
        clientSubtitleController.clear()
        stopPictureInPictureForPlayerTeardown()
        setDecoderMode(.initializing)
        pictureInPictureRendererRuntimeState.reset()
        guard markStoppedIfNeeded() else {
            mpvDebugLog("stop ignored already stopped")
            return
        }
        isPlaying = false
        MPVSystemPlaybackCoordinator.shared.deactivate(playerView: self)
        destroyMPVHandle(reason: "stop")
    }

    @objc public func seek(_ options: NSDictionary) -> Bool {
        let time = (options["time"] as? NSNumber)?.doubleValue ?? 0.0
        let autoPlay = (options["autoPlay"] as? NSNumber)?.boolValue ?? false
        guard time.isFinite else {
            return false
        }

        let requestID = (options["requestID"] as? NSString).flatMap { value in
            let string = String(value)
            return string.isEmpty ? nil : string
        } ?? UUID().uuidString
        let request = MPVSeekRequest(
            requestID: requestID,
            targetTime: max(0.0, time),
            autoPlay: autoPlay,
            playbackIntentGeneration: currentPlaybackIntentGeneration()
        )
        publishSeekTarget(request.targetTime)
        mpvDebugLog(
            "seek accepted request=\(request.requestID) time=\(request.targetTime) autoPlay=\(autoPlay)"
        )
        queue.async { [weak self] in
            self?.enqueueSeekOnMPVQueue(request)
        }
        return true
    }

    nonisolated func enqueueSeekOnMPVQueue(_ request: MPVSeekRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard mpv != nil else {
            handleSeekReply(request: request, error: MPV_ERROR_UNINITIALIZED.rawValue)
            return
        }

        let userdata = allocateMPVCommandUserdata()
        pendingSeekCommands[userdata] = PendingSeek(userdata: userdata, request: request)
        let status = commandAsync(
            "seek",
            args: [String(request.targetTime), "absolute+exact"],
            replyUserdata: userdata
        )
        guard status >= 0 else {
            pendingSeekCommands.removeValue(forKey: userdata)
            handleSeekReply(request: request, error: status)
            return
        }
        mpvDebugLog(
            "seek async queued request=\(request.requestID) userdata=\(userdata) status=\(status)"
        )
    }

    /// MPV reports a new position only on its next time update, and not at all
    /// while paused. Publishing the requested position keeps the inline
    /// controls, the system playback controls and Picture in Picture in sync,
    /// and lets repeated skip commands accumulate instead of collapsing into
    /// one interval.
    private func publishSeekTarget(_ time: TimeInterval) {
        let target = duration.isFinite && duration > 0 ? min(time, duration) : time
        currentTime = target
        updateClientSubtitle(at: target)
        notifyTime(currentTime: target, duration: duration)
        MPVSystemPlaybackCoordinator.shared.publish(playerView: self)
    }

    @objc public func updatePlayRate(_ rate: NSNumber) {
        let value = rate.doubleValue
        guard value.isFinite, value > 0.0 else { return }
        mpvDebugLog("updatePlayRate value=\(value)")
        playbackSpeed = value
        setDouble(MPVProperty.speed, value)
        MPVSystemPlaybackCoordinator.shared.publish(playerView: self)
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
        queue.async { [weak self] in
            guard let self else { return }
            self.debandEnabled = debandEnabled
            guard self.mpv != nil else { return }
            self.applyVideoRenderProperties()
        }
    }

    @objc public func updateCacheConfiguration(_ options: NSDictionary) {
        let configuration = MPVCacheConfiguration(
            isEnabled: boolValue(options["cacheEnabled"], default: true),
            duration: (options["cacheDuration"] as? NSNumber)?.doubleValue ?? MPVCacheConfiguration.defaultDuration
        )
        queue.async { [weak self] in
            guard let self else { return }
            self.cacheConfiguration = configuration
            guard self.mpv != nil else { return }
            self.applyCacheConfiguration(configuration)
        }
    }

    @objc public func mediaTracks(_ options: NSDictionary) -> NSArray {
        let requestedType = options["mediaType"] as? String
        let tracks = cachedMediaTracks(mediaType: requestedType)
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
        if mediaType == "sub" {
            clearClientSubtitle()
        }
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
        clearClientSubtitle()
        let usesOriginalStyle = boolValue(options["usesOriginalStyle"])
        queue.async { [weak self] in
            self?.loadSubtitleOnMPVQueue(
                requestID: requestID,
                urlString: urlString,
                usesOriginalStyle: usesOriginalStyle
            )
        }
    }

    nonisolated func loadSubtitleOnMPVQueue(
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

        let source = normalizedMPVSource(urlString)
        let userdata = allocateMPVCommandUserdata()
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
        let status = commandAsync(
            "sub-add",
            args: [source, "auto"],
            replyUserdata: userdata,
            handle: mpv
        )
        if status < 0 {
            pendingExternalSubtitleLoad = nil
            notifySubtitleLoad(requestID: requestID, success: false)
        }
        mpvDebugLog("loadSubtitle async request=\(requestID) userdata=\(userdata) status=\(status)")
    }

    @objc public func setSubtitleVisible(_ options: NSDictionary) {
        let visible = boolValue(options["visible"])
        clearClientSubtitle()
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
        let shadowOffset = (options["shadowOffset"] as? NSNumber)?.doubleValue ?? 0
        let shadowColor = Self.subtitleShadowColor(from: options, shadowOffset: shadowOffset)
        let isBold = boolValue(options["bold"])
        let fontName = options["fontName"] as? String ?? subtitleFontName(isBold: isBold)
        applyClientSubtitleStyle(MPVSubtitleStyle(
            fontSize: (options["fontSize"] as? NSNumber)?.doubleValue ?? 38,
            fontName: fontName,
            bold: isBold,
            textColor: options["textColor"] as? String ?? "#FFFFFFFF",
            outlineSize: (options["outlineSize"] as? NSNumber)?.doubleValue ?? 0,
            outlineColor: options["outlineColor"] as? String ?? "#FF000000",
            shadowOffset: shadowOffset,
            backgroundColor: options["backgroundColor"] as? String ?? "#00000000",
            bottomOffset: (options["bottomOffset"] as? NSNumber)?.doubleValue ?? 34,
            shadowColor: shadowColor
        ))
        let values = [
            MPVProperty.subtitleFont: fontName,
            MPVProperty.subtitleFontSize: decimalString(options["fontSize"], fallback: 38),
            MPVProperty.subtitleBold: isBold ? "yes" : "no",
            MPVProperty.subtitleColor: options["textColor"] as? String ?? "#FFFFFFFF",
            MPVProperty.subtitleOutlineSize: decimalString(options["outlineSize"], fallback: 0),
            MPVProperty.subtitleOutlineColor: options["outlineColor"] as? String ?? "#FF000000",
            // libmpv applies sub-blur to the complete subtitle glyph, rather than
            // only to its shadow. Always reset it so a previous runtime style
            // cannot leave text blurred.
            MPVProperty.subtitleBlur: "0.000",
            MPVProperty.subtitleShadowOffset: decimalString(options["shadowOffset"], fallback: 0),
            MPVProperty.subtitleBackColor: shadowColor,
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

    nonisolated static func subtitleShadowColor(
        from options: NSDictionary,
        shadowOffset: Double
    ) -> String {
        if let shadowColor = options["shadowColor"] as? String, shadowColor.isEmpty == false {
            return shadowColor
        }
        guard shadowOffset > 0,
              let backgroundColor = options["backgroundColor"] as? String,
              isVisibleSubtitleColor(backgroundColor) else {
            return "#FF000000"
        }
        return backgroundColor
    }

    nonisolated private static func isVisibleSubtitleColor(_ value: String) -> Bool {
        let clean = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6 || clean.count == 8,
              let raw = UInt64(clean, radix: 16) else {
            return false
        }
        return clean.count == 6 || ((raw >> 24) & 0xFF) > 0
    }

    @objc public func updateSubtitleDelay(_ value: NSNumber) {
        let delay = value.doubleValue
        applyClientSubtitleDelay(delay.isFinite ? delay : 0)
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

}
