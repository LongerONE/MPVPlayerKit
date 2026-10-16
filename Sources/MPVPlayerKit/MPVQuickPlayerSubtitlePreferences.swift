import Foundation

/// Only durable presentation preferences belong here. Sources, visibility and delay are session state.
struct MPVQuickPlayerSubtitlePreferences {
    struct Control {
        var position: Double
        var usesOriginalStyle = false
        var automatic = false
        var language: MPVSubtitleLanguage = .simplifiedChinese
    }

    static var layoutMode: MPVSubtitleLayoutMode {
        get { MPVSubtitleLayoutMode(rawValue: UserDefaults.standard.integer(forKey: "MPVQuickPlayer.subtitleLayoutMode")) ?? .independent }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "MPVQuickPlayer.subtitleLayoutMode") }
    }

    private static let styleKey = "MPVQuickPlayer.subtitleSharedStyle"
    private static let fontKey = "MPVQuickPlayer.subtitleSharedFont"

    private static let initialFontCleanup: Void = removeUnusedFonts()

    static func prepareFontStorage() { _ = initialFontCleanup }

    private static func removeUnusedFonts() {
        guard let directory = fontDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let current = fontURL
        for file in files where file != current {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static var fontURL: URL? {
        guard let name = UserDefaults.standard.string(forKey: fontKey),
              name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
        return fontDirectory?.appendingPathComponent(name)
    }

    private static var fontDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MPVQuickPlayer/SubtitleFonts", isDirectory: true)
    }

    static func copyFont(from url: URL) throws -> URL {
        guard let directory = fontDirectory else { throw MPVSubtitleFontError.fileNotFound }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    static func saveFont(_ url: URL?) {
        // Retain previously registered files until a later launch; libass may still reference them.
        UserDefaults.standard.set(url?.lastPathComponent, forKey: fontKey)
    }
    private static func key(_ slot: MPVSubtitleSlot) -> String {
        "MPVQuickPlayer.subtitle.\(slot.rawValue)"
    }

    static func control(in slot: MPVSubtitleSlot, defaults: UserDefaults = .standard) -> Control {
        let values = defaults.dictionary(forKey: key(slot)) ?? [:]
        let position = values["position"] as? Double ?? (slot == .primary ? 100 : 0)
        return Control(
            position: position.isFinite ? min(150, max(0, position)) : (slot == .primary ? 100 : 0),
            usesOriginalStyle: values["originalStyle"] as? Bool ?? false,
            automatic: values["automatic"] as? Bool ?? false,
            language: (values["language"] as? String).flatMap(MPVSubtitleLanguage.init(rawValue:))
                ?? .simplifiedChinese
        )
    }

    static func save(_ control: Control, in slot: MPVSubtitleSlot, defaults: UserDefaults = .standard) {
        defaults.set([
            "position": control.position,
            "originalStyle": control.usesOriginalStyle,
            "automatic": control.automatic,
            "language": control.language.rawValue,
        ], forKey: key(slot))
    }

    static func style(defaults: UserDefaults = .standard) -> MPVSubtitleStyle {
        guard let values = defaults.dictionary(forKey: styleKey) else {
            var style = MPVSubtitleStyle.defaultStyle
            if let radius = defaults.object(forKey: "MPVQuickPlayer.subtitleShadowRadius") as? Double,
               radius.isFinite {
                style.shadowRadius = min(20, max(0, radius))
            }
            save(style, defaults: defaults)
            return style
        }
        return MPVSubtitleStyle(
            fontSize: values["fontSize"] as? Double ?? 38,
            fontName: values["fontName"] as? String,
            bold: values["bold"] as? Bool ?? false,
            textColor: values["textColor"] as? String ?? "#FFFFFFFF",
            outlineSize: values["outlineSize"] as? Double ?? 0,
            outlineColor: values["outlineColor"] as? String ?? "#FF000000",
            shadowOffset: values["shadowOffset"] as? Double ?? 0,
            backgroundColor: values["backgroundColor"] as? String ?? "#00000000",
            bottomOffset: values["bottomOffset"] as? Double ?? 34,
            shadowColor: values["shadowColor"] as? String ?? "#FF000000",
            shadowRadius: values["shadowRadius"] as? Double ?? 0
        )
    }

    static func save(_ style: MPVSubtitleStyle, defaults: UserDefaults = .standard) {
        defaults.set(style.bridgeDictionary, forKey: styleKey)
        defaults.removeObject(forKey: "MPVQuickPlayer.subtitleShadowRadius")
    }
}
