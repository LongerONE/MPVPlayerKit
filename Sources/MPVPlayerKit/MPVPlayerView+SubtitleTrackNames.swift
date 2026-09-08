import Foundation

struct MPVMediaTrackDescriptor {
    let id: Int64
    let ffIndex: Int64?
    let mpvType: String
    let title: String?
    let languageCode: String?
    let codec: String?
    let codecDescription: String?
    let externalFilename: String?
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isVisualImpaired: Bool
    let isSelected: Bool
    let bitRate: Int64
}

extension MPVPlayerView {
    nonisolated static func subtitleTrackName(
        id: Int64,
        title: String? = nil,
        languageCode: String? = nil,
        codec: String? = nil,
        codecDescription: String? = nil,
        externalFilename: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        isVisualImpaired: Bool = false,
        includeTrackID: Bool = false,
        localization: String = MPVLocalization.localizationIdentifier()
    ) -> String {
        subtitleTrackName(
            for: MPVMediaTrackDescriptor(
                id: id,
                ffIndex: nil,
                mpvType: "sub",
                title: title,
                languageCode: languageCode,
                codec: codec,
                codecDescription: codecDescription,
                externalFilename: externalFilename,
                isDefault: isDefault,
                isForced: isForced,
                isHearingImpaired: isHearingImpaired,
                isVisualImpaired: isVisualImpaired,
                isSelected: false,
                bitRate: 0
            ),
            includeTrackID: includeTrackID,
            localization: localization
        )
    }

    nonisolated static func subtitleTrackName(
        for descriptor: MPVMediaTrackDescriptor,
        includeTrackID: Bool = false,
        localization: String = MPVLocalization.localizationIdentifier()
    ) -> String {
        var details: [String] = []
        let source = cleanTrackValue(descriptor.title)
            ?? externalSubtitleFilename(descriptor.externalFilename)
        if let source {
            details.append(source)
        }
        if let language = localizedLanguageName(descriptor.languageCode, localization: localization) {
            details.append(language)
        }
        if let codec = subtitleCodecName(
            codec: descriptor.codec,
            description: descriptor.codecDescription
        ) {
            details.append(codec)
        }
        let labels: [(Bool, String)] = [
            (descriptor.isDefault, MPVLocalization.string("track.default", localization: localization)),
            (descriptor.isForced, MPVLocalization.string("track.forced", localization: localization)),
            (descriptor.isHearingImpaired, MPVLocalization.string("track.hearing_impaired", localization: localization)),
            (descriptor.isVisualImpaired, MPVLocalization.string("track.visual_impaired", localization: localization)),
        ]
        details.append(contentsOf: labels.compactMap { $0.0 ? $0.1 : nil })

        var uniqueDetails: [String] = []
        for detail in details where uniqueDetails.contains(where: {
            $0.caseInsensitiveCompare(detail) == .orderedSame
        }) == false {
            uniqueDetails.append(detail)
        }
        if uniqueDetails.isEmpty {
            uniqueDetails.append(MPVLocalization.string("track.subtitle", localization: localization))
        }
        if includeTrackID {
            uniqueDetails.append(
                MPVLocalization.string(
                    "track.id",
                    localization: localization,
                    arguments: [descriptor.id]
                )
            )
        }
        return uniqueDetails.joined(separator: "·")
    }

    nonisolated static func hasSubtitleIdentity(_ descriptor: MPVMediaTrackDescriptor) -> Bool {
        cleanTrackValue(descriptor.title) != nil
            || cleanTrackValue(descriptor.externalFilename) != nil
            || cleanTrackValue(descriptor.languageCode) != nil
            || cleanTrackValue(descriptor.codec) != nil
            || cleanTrackValue(descriptor.codecDescription) != nil
    }

    private nonisolated static func externalSubtitleFilename(_ value: String?) -> String? {
        guard let value = cleanTrackValue(value) else { return nil }
        let filename = URL(fileURLWithPath: value).lastPathComponent
        let name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return cleanTrackValue(name)
    }

    private nonisolated static func localizedLanguageName(
        _ value: String?,
        localization: String
    ) -> String? {
        guard let value = cleanTrackValue(value) else { return nil }
        let languageCode = value.lowercased().split(separator: "-").first.map(String.init) ?? value
        if ["chi", "zho", "zh"].contains(languageCode) {
            return MPVLocalization.string("track.language.chinese", localization: localization)
        }
        return Locale(identifier: localization).localizedString(forLanguageCode: value) ?? value
    }

    private nonisolated static func subtitleCodecName(codec: String?, description: String?) -> String? {
        guard let codec = cleanTrackValue(codec)?.lowercased() else {
            return cleanTrackValue(description)
        }
        switch codec {
        case "hdmv_pgs_subtitle", "pgs", "pgssub", "sup":
            return "PGS"
        case "subrip", "srt":
            return "SRT"
        case "ass", "ssa":
            return "ASS"
        case "webvtt":
            return "WebVTT"
        case "dvdsub", "dvd_subtitle":
            return "DVD"
        case "dvbsub", "dvb_subtitle":
            return "DVB"
        case "xsub":
            return "XSUB"
        default:
            return cleanTrackValue(description) ?? codec
        }
    }

    private nonisolated static func cleanTrackValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
