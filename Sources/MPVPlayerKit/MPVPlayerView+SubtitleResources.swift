import Foundation

extension MPVPlayerView {
    /// 仅删除显式外挂轨道；仍被任一路占用时拒绝，先关闭对应路再移除。
    @objc @discardableResult public func removeExternalSubtitle(_ options: NSDictionary) -> Bool {
        guard isReadyToPlayReported() || isPlaybackRestarted() else { return false }
        guard let id = (options["trackID"] as? NSNumber)?.int64Value else { return false }
        var success = false
        performOnMPVQueueSync {
            guard !MPVSubtitleSlot.allCases.contains(where: { self.slotState($0).trackID == id }),
                  self.subtitleSlots.externalSources[id] != nil || self.externalURL(for: id) != nil else { return }
            success = self.command("sub-remove", args: [String(id)], checkForErrors: false) >= 0
            if success {
                self.subtitleSlots.externalSources.removeValue(forKey: id)
                self.loadedExternalSubtitleIDs = self.loadedExternalSubtitleIDs.filter { $0.value != id }
                self.refreshMediaTracksCache()
            }
        }
        return success
    }

    /// 显式 ID 重载后按来源重新识别轨道，不假设 mpv 保持原 ID。
    @objc @discardableResult public func reloadExternalSubtitle(_ options: NSDictionary) -> Bool {
        guard isReadyToPlayReported() || isPlaybackRestarted() else { return false }
        guard let id = (options["trackID"] as? NSNumber)?.int64Value else { return false }
        var success = false
        performOnMPVQueueSync {
            guard let url = self.externalURL(for: id) else { return }
            let previous = MPVSubtitleSlot.allCases.map { ($0, self.slotState($0)) }
            let before = self.subtitleTrackIDs()
            guard self.command("sub-reload", args: [String(id)], checkForErrors: false) >= 0,
                  let replacement = self.externalSubtitleTrackID(source: self.normalizedMPVSource(url), urlString: url,
                    preferringIDsNotIn: before) else { return }
            let source = self.subtitleSlots.externalSources.removeValue(forKey: id) ?? self.canonicalExternalSubtitleSource(url)
            self.subtitleSlots.externalSources[replacement] = source
            success = true
            for (slot, var state) in previous where state.trackID == id {
                state.trackID = replacement
                if self.applySlotState(state, slot: slot) {
                    self.subtitleSlots.states[slot] = state
                    self.subtitleSlots.publish(self.slotState(slot), slot: slot)
                } else {
                    success = false
                    var fallback = state
                    fallback.trackID = self.getInt64(slot.idProperty).flatMap { $0 > 0 ? $0 : nil }
                    fallback.visible = self.getFlag(slot.visibilityProperty) ?? false
                    fallback.nativeVisible = fallback.visible
                    if fallback.trackID == nil { fallback.sourceID = nil }
                    self.subtitleSlots.states[slot] = fallback
                    self.subtitleSlots.publish(fallback, slot: slot)
                }
            }
            self.refreshMediaTracksCache()
        }
        return success
    }

    nonisolated func externalURL(for id: Int64) -> String? {
        let count = Int(getInt64("track-list/count") ?? 0)
        for index in 0..<count where getInt64("track-list/\(index)/id") == id && getString("track-list/\(index)/type") == "sub" {
            return getString("track-list/\(index)/external-filename")
        }
        return nil
    }
}
