import CoreText
import UIKit

public enum MPVSubtitleFontCapability: String, Sendable {
    case noSubtitle
    case unsupported
    case supported

    public var canCustomize: Bool {
        self == .supported
    }
}

public enum MPVSubtitleFontError: Error, LocalizedError, Equatable, Sendable {
    case fileURLRequired
    case fileNotFound
    case invalidFontFile
    case registrationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileURLRequired:
            return "Subtitle font URL must point to a local file."
        case .fileNotFound:
            return "Subtitle font file does not exist."
        case .invalidFontFile:
            return "Subtitle font file does not contain a readable font."
        case let .registrationFailed(reason):
            return "Subtitle font registration failed: \(reason)"
        }
    }
}

enum MPVSubtitleFontRegistry {
    static func registerFont(from url: URL) throws -> String {
        guard url.isFileURL else {
            throw MPVSubtitleFontError.fileURLRequired
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MPVSubtitleFontError.fileNotFound
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let postScriptName = CTFontDescriptorCopyAttribute(
                descriptor,
                kCTFontNameAttribute
              ) as? String,
              postScriptName.isEmpty == false else {
            throw MPVSubtitleFontError.invalidFontFile
        }

        var registrationError: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            &registrationError
        )
        let registrationReason = registrationError?.takeRetainedValue().localizedDescription
        if registered == false, UIFont(name: postScriptName, size: 12) == nil {
            let reason = registrationReason ?? "The font is not available after registration."
            throw MPVSubtitleFontError.registrationFailed(reason)
        }
        return postScriptName
    }
}

extension MPVPlayerView {
    public func setSubtitleFont(from url: URL) throws {
        let fontName = try MPVSubtitleFontRegistry.registerFont(from: url)
        customSubtitleFontName = fontName
        applySubtitleFontConfiguration()
    }

    public func resetSubtitleFont() {
        customSubtitleFontName = nil
        applySubtitleFontConfiguration()
    }

    nonisolated func selectedSubtitleFontCapability(for trackID: Int64?) -> MPVSubtitleFontCapability {
        guard let trackID else { return .noSubtitle }
        guard let track = cachedMediaTracks(mediaType: "sub").first(where: {
            ($0["trackID"] as? NSNumber)?.int64Value == trackID
        }) else {
            return .unsupported
        }
        return (track["isImageSubtitle"] as? NSNumber)?.boolValue == true
            ? .unsupported
            : .supported
    }

    nonisolated func publishSubtitleFontCapability(for trackID: Int64?) {
        let capability = selectedSubtitleFontCapability(for: trackID)
        notifyOnMain {
            self.currentSubtitleFontCapability = capability
        }
    }

    nonisolated func subtitleFontName(isBold: Bool) -> String {
        customSubtitleFontName ?? MPVSubtitleFont.name(isBold: isBold)
    }

    func applySubtitleFontConfiguration() {
        var style = clientSubtitleController.style
        style.fontName = customSubtitleFontName
        clientSubtitleController.style = style
        clientSubtitleController.update(at: currentTime, force: true)

        queue.async { [weak self] in
            guard let self else { return }
            let isBold = self.subtitleStyleValues[MPVProperty.subtitleBold] == "yes"
            let fontName = self.subtitleFontName(isBold: isBold)
            self.subtitleStyleValues[MPVProperty.subtitleFont] = fontName
            guard self.mpv != nil else { return }
            _ = self.command(
                "set",
                args: [MPVProperty.subtitleFont, fontName],
                checkForErrors: false
            )
            guard self.currentSubtitleUsesOriginalStyle == false else { return }
            let snapshot = self.logicalSubtitleSelection()
            _ = self.performSubtitleSelectionTransaction(
                previous: snapshot,
                targetUsesOriginalStyle: false,
                targetSubtitleID: snapshot.subtitleID,
                targetVisibility: snapshot.isVisible
            )
        }
    }
}
