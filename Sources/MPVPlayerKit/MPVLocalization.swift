import Foundation

enum MPVLocalization {
    static let english = "en"
    static let simplifiedChinese = "zh-Hans"

    static func localizationIdentifier(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        guard let preferredLanguage = preferredLanguages.first,
              isSimplifiedChinese(preferredLanguage) else {
            return english
        }
        return simplifiedChinese
    }

    static func isSimplifiedChinese(_ identifier: String) -> Bool {
        let components = identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
            .split(separator: "-")
        guard components.first == "zh" else { return false }
        if components.contains("hant") { return false }
        return components.contains("hans")
            || components.contains("cn")
            || components.contains("sg")
    }

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        string(
            key,
            localization: localizationIdentifier(),
            arguments: arguments
        )
    }

    static func string(
        _ key: String,
        localization: String,
        arguments: [CVarArg] = []
    ) -> String {
        let selectedLocalization = localization == simplifiedChinese
            ? simplifiedChinese
            : english
        let selectedBundle = bundle(for: selectedLocalization)
        var format = selectedBundle.localizedString(forKey: key, value: nil, table: nil)
        if format == key, selectedLocalization != english {
            format = bundle(for: english).localizedString(forKey: key, value: nil, table: nil)
        }
        guard arguments.isEmpty == false else { return format }
        return String(
            format: format,
            locale: Locale(identifier: selectedLocalization),
            arguments: arguments
        )
    }

    private static func bundle(for localization: String) -> Bundle {
        guard let path = Bundle.module.path(forResource: localization, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.module
        }
        return bundle
    }
}

@inline(__always)
func mpvLocalized(_ key: String, _ arguments: CVarArg...) -> String {
    MPVLocalization.string(
        key,
        localization: MPVLocalization.localizationIdentifier(),
        arguments: arguments
    )
}
