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
    func logEffectiveSubtitleConfiguration() {
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

    func logSubtitleTextChange() {
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

    func logMessage(_ event: UnsafeMutablePointer<mpv_event>) {
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

    func shouldPrintMPVLogMessage(prefix: String, level: String, text: String) -> Bool {
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

    func getDouble(_ name: String) -> Double {
        guard let mpv else { return 0.0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    func getInt64(_ name: String) -> Int64? {
        guard let mpv else { return nil }
        var data = Int64()
        let status = mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        guard status >= 0 else { return nil }
        return data
    }

    func getFlag(_ name: String) -> Bool? {
        guard let mpv else { return nil }
        var data = Int32()
        let status = mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        guard status >= 0 else { return nil }
        return data != 0
    }

    func getString(_ name: String) -> String? {
        guard let mpv, let pointer = mpv_get_property_string(mpv, name) else {
            return nil
        }
        defer {
            mpv_free(UnsafeMutableRawPointer(pointer))
        }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    func refreshDecoderModeAfterPlaybackRestart() {
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

    func logVideoColorParameters() {
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

    func videoColorParameterDescription(_ properties: [String]) -> String {
        properties.map { property in
            let name = property.split(separator: "/").last.map(String.init) ?? property
            return "\(name)=\(getString(property) ?? "unavailable")"
        }
        .joined(separator: " ")
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var data = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    }

    func setFlag(_ name: String, _ flag: Bool) {
        guard let mpv else { return }
        var data: Int32 = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    var subtitleStylePropertyNames: [String] {
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
    func applySubtitleStyleMode(usesOriginalStyle: Bool) -> Bool {
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
    func applyUserSubtitleStyleProperties() -> Bool {
        var success = true
        for property in subtitleStylePropertyNames {
            guard let value = subtitleStyleValues[property] else { continue }
            success = command("set", args: [property, value], checkForErrors: false) >= 0 && success
        }
        mpvDebugLog("subtitle user style applied values=\(subtitleStyleValues)")
        return success
    }

    func subtitleTrackIDs() -> Set<Int64> {
        guard let count = getInt64("track-list/count"), count > 0 else { return [] }
        return Set((0..<Int(count)).compactMap { index in
            guard getString("track-list/\(index)/type") == "sub" else { return nil }
            return getInt64("track-list/\(index)/id")
        })
    }

    func externalSubtitleTrackID(
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

    func canonicalExternalSubtitleSource(_ source: String) -> String {
        guard let url = URL(string: source) else {
            return URL(fileURLWithPath: source).standardizedFileURL.path
        }
        return url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    func readMediaTracks(mediaType requestedType: String?) -> [[String: Any]] {
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

    func mediaTrackName(
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

    func avMediaTypeRawValue(for mpvType: String) -> String {
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

    func isImageSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else {
            return false
        }
        return codec.contains("pgs")
            || codec.contains("hdmv")
            || codec.contains("dvd_subtitle")
            || codec.contains("dvb_subtitle")
            || codec.contains("xsub")
    }

}
