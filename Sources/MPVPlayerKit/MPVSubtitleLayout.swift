import Foundation

@objc public enum MPVSubtitleLayoutMode: Int, Sendable {
    case independent = 0
    case stacked = 1
}

public enum MPVSubtitleLayoutFallbackReason: String, Sendable {
    case originalStyle, imageSubtitle, unsupportedRenderer, insufficientSpace

    public var localizationKey: String { "subtitle.layout.fallback.\(rawValue)" }
}

public struct MPVSubtitleLayoutStatus: Equatable, Sendable {
    public let requestedMode: MPVSubtitleLayoutMode
    public let fallbackReason: MPVSubtitleLayoutFallbackReason?
    public var effectiveMode: MPVSubtitleLayoutMode { fallbackReason == nil ? requestedMode : .independent }

    public init(requestedMode: MPVSubtitleLayoutMode, fallbackReason: MPVSubtitleLayoutFallbackReason? = nil) {
        self.requestedMode = requestedMode
        self.fallbackReason = fallbackReason
    }
}
