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
        stopPictureInPicture()
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

    func loadSubtitleOnMPVQueue(
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

}
