import Foundation

public struct MPVSubtitleTextSnapshot: Equatable, Sendable {
    public let text: String?
    public let assText: String?
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?
}

extension MPVPlayerView {
    /// 原生文本查询。位图字幕和当前没有活动 cue 时字段可能为空，不用于重绘完整 ASS。
    @objc public func subtitleTextSnapshot(_ value: NSNumber) -> NSDictionary {
        let slot = MPVSubtitleSlot(rawValue: value.intValue) ?? .primary
        guard isReadyToPlayReported() || isPlaybackRestarted() else {
            return ["text": NSNull(), "assText": NSNull(), "startTime": NSNull(), "endTime": NSNull()]
        }
        let prefix = slot == .primary ? "sub" : "secondary-sub"
        var result: [String: Any] = [:]
        performOnMPVQueueSync {
            result["text"] = self.getString("\(prefix)-text") ?? NSNull() as Any
            result["assText"] = self.getString("\(prefix)-text/ass-full") ?? NSNull() as Any
            let start = self.getDoubleIfAvailable("\(prefix)-start")
            let end = self.getDoubleIfAvailable("\(prefix)-end")
            result["startTime"] = start.flatMap { $0.isFinite ? $0 : nil }.map(NSNumber.init(value:)) ?? NSNull()
            result["endTime"] = end.flatMap { $0.isFinite ? $0 : nil }.map(NSNumber.init(value:)) ?? NSNull()
        }
        return result as NSDictionary
    }
}

extension MPVPlayer {
    public func subtitleTextSnapshot(in slot: MPVSubtitleSlot) -> MPVSubtitleTextSnapshot {
        let values = playbackView.subtitleTextSnapshot(NSNumber(value: slot.rawValue))
        return MPVSubtitleTextSnapshot(text: values["text"] as? String, assText: values["assText"] as? String,
            startTime: (values["startTime"] as? NSNumber)?.doubleValue,
            endTime: (values["endTime"] as? NSNumber)?.doubleValue)
    }
}
