import Foundation

@objc public enum MPVSubtitleSlot: Int, CaseIterable, Sendable {
    case primary = 0
    case secondary = 1

    var idProperty: String { self == .primary ? "sid" : "secondary-sid" }
    var visibilityProperty: String { self == .primary ? "sub-visibility" : "secondary-sub-visibility" }
    var delayProperty: String { self == .primary ? "sub-delay" : "secondary-sub-delay" }
    var positionProperty: String { self == .primary ? "sub-pos" : "secondary-sub-pos" }
    var overrideProperty: String { self == .primary ? "sub-ass-override" : "secondary-sub-ass-override" }
    var textProperty: String { self == .primary ? "sub-text" : "secondary-sub-text" }
    var other: Self { self == .primary ? .secondary : .primary }
}

public enum MPVSubtitleASSOverride: String, CaseIterable, Sendable {
    case no, yes, scale, force, strip
}

/// 当前实际渲染路径的能力；inactive 包括未选择、隐藏和正在加载的字幕。
public enum MPVSubtitleShadowRadiusCapability: String, Sendable {
    case inactive, supported, nativeRenderer, originalStyle, imageSubtitle, unsupportedRenderer
}

public struct MPVSubtitleState: Equatable, Sendable {
    public var shadowRadiusCapability: MPVSubtitleShadowRadiusCapability = .inactive
    public var assOverride: MPVSubtitleASSOverride = .strip
    public var trackID: Int64?
    public var visible: Bool
    public var nativeVisible: Bool
    public var delay: Double
    public var position: Double
    public var usesOriginalStyle: Bool
    public var sourceID: String?
    public var isNative: Bool
    public var supportsTextStyle: Bool

    init(slot: MPVSubtitleSlot) {
        trackID = nil
        visible = false
        nativeVisible = false
        delay = 0
        position = slot == .primary ? 100 : 0
        usesOriginalStyle = false
        sourceID = nil
        isNative = true
        supportsTextStyle = false
    }

    mutating func updateShadowRadiusCapability(isImageSubtitle: Bool) {
        guard trackID != nil, visible else { shadowRadiusCapability = .inactive; return }
        if isImageSubtitle { shadowRadiusCapability = .imageSubtitle }
        else if usesOriginalStyle { shadowRadiusCapability = .originalStyle }
        else { shadowRadiusCapability = isNative ? .nativeRenderer : .supported }
    }

    var dictionary: NSDictionary {
        ["trackID": trackID.map(NSNumber.init(value:)) ?? NSNull(),
         "visible": visible, "nativeVisible": nativeVisible, "delay": delay,
         "position": position, "usesOriginalStyle": usesOriginalStyle, "assOverride": assOverride.rawValue,
         "sourceID": sourceID ?? "", "isNative": isNative,
         "supportsTextStyle": supportsTextStyle,
         "shadowRadiusCapability": shadowRadiusCapability.rawValue] as NSDictionary
    }
}

public enum MPVSubtitleLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese
    case traditionalChinese
    case english
}

/// 仅排序当前目录中可用的轨道，不下载、不持久化来源。
public enum MPVSubtitleAutoSelection {
    public static func rank(
        tracks: [MPVMediaTrack], language: MPVSubtitleLanguage,
        excludingTrackIDs: Set<Int32> = []
    ) -> [MPVMediaTrack] {
        tracks.enumerated().filter {
            $0.element.type == .subtitle && !excludingTrackIDs.contains($0.element.id)
                && score($0.element, language: language) > 0
        }.sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            let sa = score(a, language: language), sb = score(b, language: language)
            if sa != sb { return sa > sb }
            if a.isForced != b.isForced { return !a.isForced }
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.isImageSubtitle != b.isImageSubtitle { return !a.isImageSubtitle }
            if a.isExternal != b.isExternal { return a.isExternal }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func score(_ track: MPVMediaTrack, language: MPVSubtitleLanguage) -> Int {
        let code = (track.languageCode ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
        let title = track.name.lowercased()
        let simplified = ["hans", "简体", "簡體", "简中", "chs", "zh-cn", "zh-sg"].contains { code.contains($0) || title.contains($0) }
        let traditional = ["hant", "繁体", "繁體", "繁中", "cht", "zh-tw", "zh-hk"].contains { code.contains($0) || title.contains($0) }
        switch language {
        case .simplifiedChinese:
            if traditional && !simplified { return 0 }
            if simplified { return 300 }
            if ["zh", "zho", "chi", "cmn"].contains(code) { return 200 }
            return ["中文", "chinese"].contains(where: title.contains) ? 100 : 0
        case .traditionalChinese:
            if simplified && !traditional { return 0 }
            if traditional { return 300 }
            if ["zh", "zho", "chi", "cmn"].contains(code) { return 200 }
            return ["中文", "chinese"].contains(where: title.contains) ? 100 : 0
        case .english:
            if code == "en" || code == "eng" || code.hasPrefix("en-") { return 300 }
            return ["english", "英文", "英语", "英語"].contains(where: title.contains) ? 100 : 0
        }
    }
}

/// 仅由播放器串行队列访问；不包含公共样式，回滚不会覆盖新的样式设置。
final class MPVSubtitleSlotRuntime: @unchecked Sendable {
    let snapshotLock = NSLock()
    private var published: [MPVSubtitleSlot: MPVSubtitleState] = [:]
    private var publishedRevision: [MPVSubtitleSlot: UInt64] = [:]
    func publishRevision(_ value: UInt64, slot: MPVSubtitleSlot) {
        snapshotLock.lock(); publishedRevision[slot] = value; snapshotLock.unlock()
    }
    func revision(_ slot: MPVSubtitleSlot) -> UInt64 {
        snapshotLock.lock(); defer { snapshotLock.unlock() }; return publishedRevision[slot] ?? 0
    }
    func publish(_ state: MPVSubtitleState, slot: MPVSubtitleSlot) {
        snapshotLock.lock()
        published[slot] = state
        snapshotLock.unlock()
    }
    func snapshot(_ slot: MPVSubtitleSlot) -> MPVSubtitleState {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return published[slot] ?? MPVSubtitleState(slot: slot)
    }
    var states: [MPVSubtitleSlot: MPVSubtitleState] = [
        .primary: MPVSubtitleState(slot: .primary), .secondary: MPVSubtitleState(slot: .secondary)
    ]
    var delays: [String: Double] = [:]
    var pending: [UInt64: Load] = [:]
    var completedRequests: Set<String> = []
    var canceled: [UInt64: Load] = [:]
    var generation: UInt64 = 0
    var externalSources: [Int64: String] = [:]
    var restoreSnapshot: [String: Any]?
    var restorationRequests: Set<String> = []
    var fileLoaded = false
    var selectionRevision: [MPVSubtitleSlot: UInt64] = [.primary: 0, .secondary: 0]

    struct Load {
        let requestID: String
        let slot: MPVSubtitleSlot
        let url: String
        let sourceID: String
        let original: Bool
        let before: Set<Int64>
        let session: UInt64
        let generation: UInt64
        let previous: MPVSubtitleState
    }
}
