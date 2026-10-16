import Foundation

extension MPVPlayerView {
    /// 只供同一媒体播放会话的引擎重建使用，禁止写入长期配置。
    @objc public func subtitleSessionSnapshot() -> NSDictionary {
        var snapshot: [String: Any] = [:]
        guard isReadyToPlayReported() || isPlaybackRestarted() else { return snapshot as NSDictionary }
        performOnMPVQueueSync {
            snapshot["slots"] = MPVSubtitleSlot.allCases.map { slot -> [String: Any] in
                var values = self.slotState(slot).dictionary as! [String: Any]
                values["slot"] = slot.rawValue
                if let id = self.slotState(slot).trackID {
                    let count = Int(self.getInt64("track-list/count") ?? 0)
                    for index in 0..<count where self.getInt64("track-list/\(index)/id") == id {
                        values["url"] = self.getString("track-list/\(index)/external-filename")
                    }
                }
                // 同来源复用轨道时，轨道文件名可能已过期；恢复使用最近成功加载的资源。
                if let source = self.slotState(slot).sourceID, let url = self.subtitleSlots.externalSourceURLs[source] {
                    values["url"] = url
                }
                return values
            }
            snapshot["delays"] = self.subtitleSlots.delays
        }
        snapshot["layoutMode"] = subtitleLayoutMode.rawValue
        if let document = clientSubtitleController.document {
            if var slots = snapshot["slots"] as? [[String: Any]], !slots.isEmpty {
                slots[0]["trackID"] = NSNull()
                slots[0]["sourceID"] = "client-document"
                slots[0]["url"] = nil
                slots[0]["visible"] = false
                snapshot["slots"] = slots
            }
            snapshot["clientDocument"] = MPVSubtitleDocumentSnapshot(document: document)
            snapshot["clientVisible"] = clientSubtitleController.isVisible
            snapshot["clientDelay"] = clientSubtitleController.delay
            snapshot["clientRenderer"] = clientSubtitleController.renderer
        }
        return snapshot as NSDictionary
    }

    @objc public func restoreSubtitleSession(_ snapshot: NSDictionary) {
        let values = snapshot as? [String: Any] ?? [:]
        if let raw = values["layoutMode"] as? Int, let mode = MPVSubtitleLayoutMode(rawValue: raw) { subtitleLayoutMode = mode }
        if let box = values["clientDocument"] as? MPVSubtitleDocumentSnapshot {
            if let renderer = values["clientRenderer"] as? any MPVSubtitleRenderer { useClientSubtitleRenderer(renderer) }
            selectClientSubtitle(box.document)
            applyClientSubtitleVisibility(values["clientVisible"] as? Bool ?? true)
            applyClientSubtitleDelay(values["clientDelay"] as? Double ?? 0)
        }
        let transfer = MPVSubtitleSessionTransfer(values: values)
        queue.async { [weak self] in
            self?.subtitleSlots.pendingControls.removeAll()
            self?.subtitleSlots.restoreSnapshot = transfer.values
            self?.restoreSubtitleSlotsIfNeeded()
        }
    }

    nonisolated func restoreSubtitleSlotsIfNeeded() {
        guard mpv != nil, let snapshot = subtitleSlots.restoreSnapshot,
              let slots = snapshot["slots"] as? [[String: Any]], subtitleSlots.fileLoaded else { return }
        subtitleSlots.restoreSnapshot = nil
        subtitleSlots.delays = snapshot["delays"] as? [String: Double] ?? [:]
        for values in slots {
            let slot = MPVSubtitleSlot(rawValue: values["slot"] as? Int ?? 0) ?? .primary
            var state = MPVSubtitleState(slot: slot)
            state.delay = values["delay"] as? Double ?? 0
            state.position = values["position"] as? Double ?? state.position
            state.visible = values["visible"] as? Bool ?? false
            state.usesOriginalStyle = values["usesOriginalStyle"] as? Bool ?? false
            state.assOverride = (values["assOverride"] as? String).flatMap(MPVSubtitleASSOverride.init(rawValue:)) ?? (state.usesOriginalStyle ? .no : .strip)
            applyPendingSubtitleControls(to: &state, slot: slot)
            state.sourceID = (values["sourceID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let source = state.sourceID {
                state.trackID = subtitleTrackIDs().first { sourceIdentity($0) == source }
            }
            if state.trackID == nil, let url = values["url"] as? String {
                let request = UUID().uuidString
                let load = MPVSubtitleSlotRuntime.Load(requestID: request, slot: slot, url: url,
                    sourceID: state.sourceID ?? canonicalExternalSubtitleSource(url), original: state.usesOriginalStyle,
                    before: subtitleTrackIDs(), session: currentBufferingSessionGeneration(),
                    generation: subtitleSlots.generation, previous: state)
                let userdata = allocateMPVCommandUserdata()
                subtitleSlots.states[slot] = state
                subtitleSlots.pending[userdata] = load
                subtitleSlots.restorationRequests.insert(request)
                if commandAsync("sub-add", args: [normalizedMPVSource(url), "auto"], replyUserdata: userdata) < 0 {
                    subtitleSlots.pending.removeValue(forKey: userdata)
                    finishSlotLoad(load, success: false, error: "恢复字幕失败")
                }
            } else if applySlotState(state, slot: slot) {
                if let source = state.sourceID { subtitleSlots.delays[source] = state.delay }
                subtitleSlots.pendingControls.removeValue(forKey: slot)
            }
        }
    }

    /// 正在恢复或加载时，明确的新设置优先于旧快照；不写入长期偏好。
    nonisolated func recordPendingSubtitleControls(
        slot: MPVSubtitleSlot, delay: Double? = nil, position: Double? = nil,
        visible: Bool? = nil, assOverride: MPVSubtitleASSOverride? = nil
    ) {
        guard subtitleSlots.restoreSnapshot != nil || subtitleSlots.pending.values.contains(where: { $0.slot == slot }) else { return }
        var controls = subtitleSlots.pendingControls[slot] ?? .init()
        if let delay, delay.isFinite { controls.delay = delay }
        if let position, position.isFinite { controls.position = min(150, max(0, position)) }
        if let visible { controls.visible = visible }
        if let assOverride { controls.assOverride = assOverride }
        subtitleSlots.pendingControls[slot] = controls
    }

    nonisolated func applyPendingSubtitleControls(to state: inout MPVSubtitleState, slot: MPVSubtitleSlot) {
        subtitleSlots.pendingControls[slot]?.apply(to: &state)
    }

    nonisolated func resetSubtitleSlotSession() {
        subtitleSlots.generation &+= 1
        subtitleSlots.restoreSnapshot = nil
        subtitleSlots.pendingControls.removeAll()
        subtitleSlots.fileLoaded = false
        subtitleSlots.restorationRequests.removeAll()
        let pending = Array(subtitleSlots.pending.values)
        subtitleSlots.pending.removeAll()
        pending.forEach { finishSlotLoad($0, success: false, error: "播放会话已结束") }
        subtitleSlots.states = [.primary: MPVSubtitleState(slot: .primary), .secondary: MPVSubtitleState(slot: .secondary)]
        subtitleSlots.delays.removeAll()
        subtitleSlots.externalSources.removeAll()
        subtitleSlots.externalSourceURLs.removeAll()
        subtitleSlots.completedRequests.removeAll()
        subtitleSlots.canceled.removeAll()
        for slot in MPVSubtitleSlot.allCases { subtitleSlots.publish(MPVSubtitleState(slot: slot), slot: slot) }
        subtitleDelayValue = 0
    }
}

private final class MPVSubtitleDocumentSnapshot: NSObject, @unchecked Sendable {
    let document: MPVSubtitleDocument
    init(document: MPVSubtitleDocument) { self.document = document }
}

final class MPVSubtitleSessionTransfer: @unchecked Sendable {
    let values: [String: Any]
    init(values: [String: Any]) { self.values = values }
}
