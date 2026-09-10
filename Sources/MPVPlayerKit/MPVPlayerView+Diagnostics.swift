import AVFoundation
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

extension MPVPlayerView {
    nonisolated func logMessage(_ event: UnsafeMutablePointer<mpv_event>) {
        dispatchPrecondition(condition: .onQueue(queue))
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
        mpvDebugLog(
            "mpv log prefix=\(prefix) level=\(level) "
                + "text=\(text)\(repetitionSuffix)"
        )
        #endif
    }

    nonisolated func shouldPrintMPVLogMessage(prefix: String, level: String, text: String) -> Bool {
        switch level {
        case "fatal", "error", "warn":
            return true
        default:
            break
        }

        let normalizedPrefix = prefix.lowercased()
        if normalizedPrefix.contains("libass")
            || normalizedPrefix.contains("subtitle")
            || normalizedPrefix.hasPrefix("sub")
            || normalizedPrefix.hasPrefix("vo/gpu")
            || normalizedPrefix.hasPrefix("vd/")
            || normalizedPrefix.contains("libplacebo")
            || normalizedPrefix == "ffmpeg/video" {
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

    nonisolated func renderingDiagnosticDescription() -> String {
        let propertyNames = [
            "vo",
            "gpu-api",
            "gpu-context",
            "hwdec",
            "hwdec-current",
            "vd-lavc-dr",
            "fbo-format",
            "target-colorspace-hint",
            "target-colorspace-hint-mode",
            "blend-subtitles",
            "sub-hdr-peak",
            "image-subs-hdr-peak",
        ]
        return propertyNames.map { name in
            "\(name)=\(getString(name) ?? "<unavailable>")"
        }.joined(separator: " ")
    }

    nonisolated func getDouble(_ name: String) -> Double {
        guard let mpv else { return 0.0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    nonisolated func getDoubleIfAvailable(_ name: String) -> Double? {
        guard let mpv else { return nil }
        var data = Double()
        let status = mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        guard status >= 0, data.isFinite else { return nil }
        return data
    }

    nonisolated func getInt64(_ name: String) -> Int64? {
        guard let mpv else { return nil }
        var data = Int64()
        let status = mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        guard status >= 0 else { return nil }
        return data
    }

    nonisolated func getFlag(_ name: String) -> Bool? {
        guard let mpv else { return nil }
        var data = Int32()
        let status = mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        guard status >= 0 else { return nil }
        return data != 0
    }

    nonisolated func getString(_ name: String) -> String? {
        guard let mpv, let pointer = mpv_get_property_string(mpv, name) else {
            return nil
        }
        defer {
            mpv_free(UnsafeMutableRawPointer(pointer))
        }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    nonisolated func refreshDecoderModeAfterPlaybackRestart() {
        mpvDebugLog("decoder diagnostics read hwdec-current begin")
        guard let activeHWDec = getString(MPVProperty.hwdecCurrent)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              activeHWDec.isEmpty == false else {
            mpvDebugLog("decoder diagnostics read hwdec-current unavailable")
            mpvDebugLog("decoder mode remains initializing because hwdec-current is unavailable profile=\(activeProfileDescription)")
            setDecoderMode(.initializing)
            return
        }
        mpvDebugLog(
            "decoder diagnostics read hwdec-current end value=\(activeHWDec)"
        )

        let decoderMode: MPVPlayerDecoderMode = activeHWDec.caseInsensitiveCompare("no") == .orderedSame
            ? .software
            : .hardware
        mpvDebugLog("decoder mode confirmed activeHWDec=\(activeHWDec) mode=\(decoderMode) profile=\(activeProfileDescription)")
        setDecoderMode(decoderMode)
    }

    nonisolated func logVideoColorParameters() {
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

    nonisolated func videoColorParameterDescription(_ properties: [String]) -> String {
        properties.map { property in
            let name = property.split(separator: "/").last.map(String.init) ?? property
            return "\(name)=\(getString(property) ?? "unavailable")"
        }
        .joined(separator: " ")
    }

    nonisolated func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var data = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    }

    func setFlag(_ name: String, _ flag: Bool) {
        guard let mpv else { return }
        var data: Int32 = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    nonisolated var subtitleStylePropertyNames: [String] {
        [
            MPVProperty.subtitleFont,
            MPVProperty.subtitleFontSize,
            MPVProperty.subtitleBold,
            MPVProperty.subtitleColor,
            MPVProperty.subtitleOutlineSize,
            MPVProperty.subtitleOutlineColor,
            MPVProperty.subtitleBlur,
            MPVProperty.subtitleShadowOffset,
            MPVProperty.subtitleBackColor,
            MPVProperty.subtitleBorderStyle,
            MPVProperty.subtitleMarginY,
        ]
    }

    func decimalString(_ value: Any?, fallback: Double) -> String {
        let number = (value as? NSNumber)?.doubleValue ?? fallback
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), number.isFinite ? number : fallback)
    }

    func subtitleMarginYString(_ bottomOffset: Any?) -> String {
        let offset = (bottomOffset as? NSNumber)?.doubleValue ?? 0
        guard offset.isFinite else { return "34" }
        return String(max(0, 34 + Int(offset.rounded())))
    }

    @discardableResult
    nonisolated func applySubtitleStyleMode(usesOriginalStyle: Bool) -> Bool {
        let override = usesOriginalStyle ? "no" : "strip"
        let status = command("set", args: [MPVProperty.subtitleASSOverride, override], checkForErrors: false)
        mpvDebugLog("subtitle style mode original=\(usesOriginalStyle) assOverride=\(override) status=\(status)")
        guard status >= 0 else { return false }
        if usesOriginalStyle == false, applyUserSubtitleStyleProperties() == false {
            return false
        }
        return true
    }

    func applyUserSubtitleStyleOptions(to handle: OpaquePointer) {
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
    nonisolated func applyUserSubtitleStyleProperties() -> Bool {
        var success = true
        for property in subtitleStylePropertyNames {
            guard let value = subtitleStyleValues[property] else { continue }
            success = command("set", args: [property, value], checkForErrors: false) >= 0 && success
        }
        mpvDebugLog("subtitle user style applied values=\(subtitleStyleValues)")
        return success
    }

    nonisolated func subtitleTrackIDs() -> Set<Int64> {
        guard let count = getInt64("track-list/count"), count > 0 else { return [] }
        var trackIDs = Set<Int64>()
        for index in 0..<Int(count) {
            guard getString("track-list/\(index)/type") == "sub",
                  let trackID = getInt64("track-list/\(index)/id") else {
                continue
            }
            trackIDs.insert(trackID)
        }
        return trackIDs
    }

    nonisolated func externalSubtitleTrackID(
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

    nonisolated func canonicalExternalSubtitleSource(_ source: String) -> String {
        guard let url = URL(string: source) else {
            return URL(fileURLWithPath: source).standardizedFileURL.path
        }
        return url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    nonisolated func refreshMediaTracksCache() {
        dispatchPrecondition(condition: .onQueue(queue))
        let tracks = readMediaTracks(mediaType: nil)
        mediaTracksCacheLock.lock()
        mediaTracksCache = tracks
        mediaTracksCacheLock.unlock()
        mpvDebugLog("refreshed media tracks cache count=\(tracks.count)")
    }

    nonisolated func cachedMediaTracks(mediaType requestedType: String?) -> [[String: Any]] {
        mediaTracksCacheLock.lock()
        let tracks = mediaTracksCache
        mediaTracksCacheLock.unlock()
        guard let requestedType else {
            return tracks
        }
        return tracks.filter { $0["mpvType"] as? String == requestedType }
    }

    nonisolated func clearMediaTracksCache() {
        mediaTracksCacheLock.lock()
        mediaTracksCache.removeAll(keepingCapacity: false)
        mediaTracksCacheLock.unlock()
    }

    nonisolated func refreshSubtitleTextCache() {
        dispatchPrecondition(condition: .onQueue(queue))
        let raw = getString(MPVProperty.subtitleText)
        let cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (cleaned?.isEmpty == false) ? raw : nil
        subtitleTextCacheLock.lock()
        cachedSubtitleText = value
        subtitleTextCacheLock.unlock()
    }

    nonisolated func cachedSubtitleTextValue() -> String? {
        subtitleTextCacheLock.lock()
        defer { subtitleTextCacheLock.unlock() }
        return cachedSubtitleText
    }

    nonisolated func clearSubtitleTextCache() {
        subtitleTextCacheLock.lock()
        cachedSubtitleText = nil
        subtitleTextCacheLock.unlock()
    }

    nonisolated func readMediaTracks(mediaType requestedType: String?) -> [[String: Any]] {
        guard let count = getInt64("track-list/count"), count > 0 else {
            return []
        }

        var descriptors: [MPVMediaTrackDescriptor] = []
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

            let ffIndex = getInt64("track-list/\(index)/ff-index")
            let title = getString("track-list/\(index)/title")
            let languageCode = getString("track-list/\(index)/lang")
            let codec = getString("track-list/\(index)/codec")
            descriptors.append(MPVMediaTrackDescriptor(
                id: trackID,
                ffIndex: ffIndex,
                mpvType: mpvType,
                title: title,
                languageCode: languageCode,
                codec: codec,
                codecDescription: getString("track-list/\(index)/codec-desc"),
                externalFilename: getString("track-list/\(index)/external-filename"),
                isDefault: getFlag("track-list/\(index)/default") ?? false,
                isForced: getFlag("track-list/\(index)/forced") ?? false,
                isHearingImpaired: getFlag("track-list/\(index)/hearing-impaired") ?? false,
                isVisualImpaired: getFlag("track-list/\(index)/visual-impaired") ?? false,
                isSelected: getFlag("track-list/\(index)/selected") ?? false,
                bitRate: getInt64("track-list/\(index)/demux-bitrate")
                    ?? getInt64("track-list/\(index)/bitrate")
                    ?? 0
            ))
        }

        let subtitleGroups = Dictionary(
            grouping: descriptors.filter { $0.mpvType == "sub" },
            by: { Self.subtitleTrackName(for: $0) }
        )
        var duplicateSubtitleIDs = Set<Int64>()
        for group in subtitleGroups.values where group.count > 1 {
            duplicateSubtitleIDs.formUnion(group.map(\.id))
        }

        return descriptors.map { descriptor in
            let name: String
            if descriptor.mpvType == "sub" {
                name = Self.subtitleTrackName(
                    for: descriptor,
                    includeTrackID: duplicateSubtitleIDs.contains(descriptor.id)
                        || Self.hasSubtitleIdentity(descriptor) == false
                )
            } else {
                name = mediaTrackName(
                    id: descriptor.id,
                    mpvType: descriptor.mpvType,
                    title: descriptor.title,
                    languageCode: descriptor.languageCode,
                    codec: descriptor.codec
                )
            }

            var track: [String: Any] = [
                "trackID": NSNumber(value: Int32(clamping: descriptor.id)),
                "subtitleID": "mpv-\(descriptor.mpvType)-\(descriptor.id)",
                "name": name,
                "mediaType": avMediaTypeRawValue(for: descriptor.mpvType),
                "mpvType": descriptor.mpvType,
                "codec": descriptor.codec ?? "",
                "isEnabled": NSNumber(value: descriptor.isSelected),
                "isImageSubtitle": NSNumber(value: isImageSubtitleCodec(descriptor.codec)),
                "nominalFrameRate": NSNumber(value: 0),
                "bitRate": NSNumber(value: descriptor.bitRate),
                "bitDepth": NSNumber(value: 0),
                "rotation": NSNumber(value: 0),
            ]
            if let ffIndex = descriptor.ffIndex {
                track["ffIndex"] = NSNumber(value: Int32(clamping: ffIndex))
            }
            if let languageCode = descriptor.languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
               languageCode.isEmpty == false {
                track["languageCode"] = languageCode
            }
            return track
        }
    }

    nonisolated func mediaTrackName(
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

    nonisolated func avMediaTypeRawValue(for mpvType: String) -> String {
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

    func mpvSelectionProperty(for mediaType: String) -> String? {
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

    nonisolated func isImageSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else {
            return false
        }
        return codec.contains("pgs")
            || codec.contains("hdmv")
            || codec.contains("sup")
            || codec.contains("dvd_subtitle")
            || codec.contains("dvb_subtitle")
            || codec.contains("xsub")
    }

}
