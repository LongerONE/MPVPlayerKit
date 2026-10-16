import Foundation

extension MPVPlayer {
    @discardableResult public func select(track: MPVMediaTrack, in slot: MPVSubtitleSlot) -> Bool {
        guard track.type == .subtitle else { select(track: track); return true }
        return playbackView.selectSubtitleTrack([
            "slot": slot.rawValue, "trackID": track.id,
            "usesOriginalStyle": subtitleState(in: slot).usesOriginalStyle
        ])
    }

    @discardableResult public func clearSubtitle(in slot: MPVSubtitleSlot) -> Bool {
        playbackView.selectSubtitleTrack(["slot": slot.rawValue, "trackID": -1])
    }

    public func setSubtitlesVisible(_ visible: Bool, in slot: MPVSubtitleSlot) {
        playbackView.setSubtitleVisible(["slot": slot.rawValue, "visible": visible])
    }

    public func setSubtitleDelay(_ delay: TimeInterval, in slot: MPVSubtitleSlot) {
        playbackView.updateSubtitleControl(["slot": slot.rawValue, "delay": delay])
    }

    public func setSubtitlePosition(_ position: Double, in slot: MPVSubtitleSlot) {
        playbackView.updateSubtitleControl(["slot": slot.rawValue, "position": position])
    }

    public func setSubtitleUsesOriginalStyle(_ value: Bool, in slot: MPVSubtitleSlot) {
        playbackView.updateSubtitleControl(["slot": slot.rawValue, "usesOriginalStyle": value])
    }

    public func setSubtitleASSOverride(_ value: MPVSubtitleASSOverride, in slot: MPVSubtitleSlot) {
        playbackView.updateSubtitleControl(["slot": slot.rawValue, "assOverride": value.rawValue])
    }

    public func subtitleState(in slot: MPVSubtitleSlot) -> MPVSubtitleState {
        let values = playbackView.subtitleState(NSNumber(value: slot.rawValue))
        var state = MPVSubtitleState(slot: slot)
        state.trackID = (values["trackID"] as? NSNumber)?.int64Value
        state.visible = (values["visible"] as? NSNumber)?.boolValue ?? false
        state.nativeVisible = (values["nativeVisible"] as? NSNumber)?.boolValue ?? false
        state.delay = (values["delay"] as? NSNumber)?.doubleValue ?? 0
        state.position = (values["position"] as? NSNumber)?.doubleValue ?? state.position
        state.assOverride = (values["assOverride"] as? String).flatMap(MPVSubtitleASSOverride.init(rawValue:)) ?? .strip
        state.usesOriginalStyle = (values["usesOriginalStyle"] as? NSNumber)?.boolValue ?? false
        state.sourceID = (values["sourceID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        state.isNative = (values["isNative"] as? NSNumber)?.boolValue ?? true
        state.supportsTextStyle = (values["supportsTextStyle"] as? NSNumber)?.boolValue ?? false
        return state
    }

    public func currentSubtitleText(in slot: MPVSubtitleSlot) -> String? {
        playbackView.subtitleText(NSNumber(value: slot.rawValue)) as String?
    }

    @discardableResult public func loadExternalSubtitle(
        from url: URL, in slot: MPVSubtitleSlot, usesOriginalStyle: Bool = false,
        completion: @escaping (Bool) -> Void
    ) -> UUID {
        registerSubtitleLoad(url: url, slot: slot, usesOriginalStyle: usesOriginalStyle, completion: completion)
    }

    @discardableResult public func removeExternalSubtitle(trackID: Int64) -> Bool {
        playbackView.removeExternalSubtitle(["trackID": trackID])
    }

    @discardableResult public func reloadExternalSubtitle(trackID: Int64) -> Bool {
        playbackView.reloadExternalSubtitle(["trackID": trackID])
    }

    /// 仅在内存传给同一媒体的新引擎，包含渲染器引用，不能序列化或长期保存。
    public func subtitleSessionSnapshot() -> NSDictionary { playbackView.subtitleSessionSnapshot() }
    public func restoreSubtitleSession(_ snapshot: NSDictionary) { playbackView.restoreSubtitleSession(snapshot) }
}
