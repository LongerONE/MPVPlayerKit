import Foundation

/// 公共半径只应用于支持的活动字幕；文字由宿主提供本地化。
public struct MPVSubtitleShadowRadiusAvailability: Equatable, Sendable {
    public let capabilities: [MPVSubtitleSlot: MPVSubtitleShadowRadiusCapability]

    public init(capabilities: [MPVSubtitleSlot: MPVSubtitleShadowRadiusCapability]) {
        self.capabilities = capabilities
    }

    public var isEditable: Bool { capabilities.values.contains(.supported) }

    public func explanation(localize: (String) -> String) -> String? {
        let active = MPVSubtitleSlot.allCases.filter { capabilities[$0] != nil && capabilities[$0] != .inactive }
        guard !active.isEmpty else { return localize("subtitle.shadow_radius.no_subtitle") }
        let unsupported = active.filter { capabilities[$0] != .supported }
        guard !unsupported.isEmpty else { return nil }
        var lines: [String] = []
        if isEditable {
            let supported = active.filter { capabilities[$0] == .supported }.map {
                localize($0 == .primary ? "subtitle.primary" : "subtitle.secondary")
            }.joined(separator: localize("subtitle.shadow_radius.separator"))
            lines.append(String(format: localize("subtitle.shadow_radius.applies_to"), supported))
        }
        for slot in unsupported {
            guard let capability = capabilities[slot] else { continue }
            let title = localize(slot == .primary ? "subtitle.primary" : "subtitle.secondary")
            lines.append(String(format: localize("subtitle.shadow_radius.\(capability.rawValue)"), title))
        }
        return lines.joined(separator: "\n")
    }
}
