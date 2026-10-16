import Foundation
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#endif

extension MPVPlayerView {
    func subtitleSlot(_ options: NSDictionary) -> MPVSubtitleSlot {
        MPVSubtitleSlot(rawValue: (options["slot"] as? NSNumber)?.intValue ?? 0) ?? .primary
    }

    @objc public func subtitleState(_ value: NSNumber) -> NSDictionary {
        let slot = MPVSubtitleSlot(rawValue: value.intValue) ?? .primary
        var state = subtitleSlots.snapshot(slot)
        if slot == .primary, clientSubtitleController.hasSelection {
            state.sourceID = "client-document"
            state.delay = clientSubtitleController.delay
            state.isNative = false
            state.visible = clientSubtitleController.isVisible
            state.supportsTextStyle = true
            state.usesOriginalStyle = false
            state.supportsASSMode = false
            state.shadowRadiusCapability = state.visible ? .supported : .inactive
        }
        if state.shadowRadiusCapability == .supported, !clientSubtitleController.renderer.supportsShadowRadius {
            state.shadowRadiusCapability = .unsupportedRenderer
        }
        return state.dictionary
    }

    @objc public func subtitleText(_ value: NSNumber) -> NSString? {
        let slot = MPVSubtitleSlot(rawValue: value.intValue) ?? .primary
        if slot == .primary { return currentSubtitleText() }
        guard isReadyToPlayReported() || isPlaybackRestarted() else { return nil }
        var text: String?
        performOnMPVQueueSync { text = self.getString(slot.textProperty) }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text as NSString
    }

    /// 返回实际事务结果；占用冲突保持当前两路状态。
    @objc @discardableResult public func selectSubtitleTrack(_ options: NSDictionary) -> Bool {
        let slot = subtitleSlot(options)
        guard isReadyToPlayReported() || isPlaybackRestarted() else { return false }
        let id = (options["trackID"] as? NSNumber)?.int64Value ?? -1
        let original = (options["usesOriginalStyle"] as? NSNumber)?.boolValue
        let source = options["sourceID"] as? String
        var success = false
        performOnMPVQueueSync {
            self.subtitleSlots.selectionRevision[slot, default: 0] &+= 1
            self.subtitleSlots.publishRevision(self.subtitleSlots.selectionRevision[slot, default: 0], slot: slot)
            self.cancelSlotLoads(slot)
            success = self.selectSlot(slot, id: id > 0 ? id : nil, sourceID: source, original: original ?? self.slotState(slot).usesOriginalStyle)
        }
        if success, slot == .primary { clearClientSubtitle() }
        return success
    }

    @objc public func updateSubtitleControl(_ options: NSDictionary) {
        let slot = subtitleSlot(options)
        let delay = (options["delay"] as? NSNumber)?.doubleValue
        let position = (options["position"] as? NSNumber)?.doubleValue
        let original = (options["usesOriginalStyle"] as? NSNumber)?.boolValue
        let override = (options["assOverride"] as? String).flatMap(MPVSubtitleASSOverride.init(rawValue:))
        if slot == .primary, let delay, delay.isFinite { applyClientSubtitleDelay(delay) }
        if slot == .primary, let position, position.isFinite,
           let renderer = clientSubtitleController.renderer as? MPVDefaultSubtitleRenderer {
            renderer.verticalPosition = min(150, max(0, position))
            clientSubtitleController.update(at: currentTime, force: true)
            if decodedSubtitleText != nil { renderDecodedSubtitleText() }
        }
        queue.async { [weak self] in
            guard let self else { return }
            var state = self.slotState(slot)
            let previous = state
            if let delay, delay.isFinite { state.delay = delay }
            if let position, position.isFinite { state.position = min(150, max(0, position)) }
            if let original { state.usesOriginalStyle = original; state.assOverride = original ? .no : .strip }
            if let override { state.assOverride = override; state.usesOriginalStyle = override == .no }
            state = self.resolvedSubtitleStyleMode(state)
            guard self.applySlotState(state, slot: slot) else {
                _ = self.applySlotState(previous, slot: slot)
                return
            }
            self.subtitleSlots.states[slot] = state
            self.subtitleSlots.publish(self.slotState(slot), slot: slot)
            if slot == .primary {
                let appliedDelay = state.delay
                self.notifyOnMain { self.applyClientSubtitleDelay(appliedDelay) }
            }
            if let source = state.sourceID { self.subtitleSlots.delays[source] = state.delay }
        }
    }

    nonisolated func slotState(_ slot: MPVSubtitleSlot) -> MPVSubtitleState {
        var state = subtitleSlots.states[slot] ?? MPVSubtitleState(slot: slot)
        if slot == .primary {
            let primary = logicalSubtitleSelection()
            state.trackID = primary.subtitleID.flatMap { $0 > 0 ? $0 : nil }
            state.visible = primary.isVisible
            state.usesOriginalStyle = primary.usesOriginalStyle
            state.isNative = !rendersDecodedSubtitleText
            state.delay = subtitleDelayValue
            if state.sourceID == nil, let id = state.trackID { state.sourceID = sourceIdentity(id) }
        }
        state.nativeVisible = getFlag(slot.visibilityProperty) ?? false
        state = resolvedSubtitleStyleMode(state)
        if let id = state.trackID {
            let image = isImageTrack(id)
            state.supportsTextStyle = !image && !state.usesOriginalStyle
            state.updateShadowRadiusCapability(isImageSubtitle: image)
        }
        if state.trackID == nil || !state.visible { state.shadowRadiusCapability = .inactive }
        if subtitleSlots.pending.values.contains(where: { $0.slot == slot }) {
            state.shadowRadiusCapability = .inactive
            state.supportsASSMode = false
        }
        return state
    }

    nonisolated func sourceIdentity(_ id: Int64) -> String {
        if let source = subtitleSlots.externalSources[id] { return source }
        let count = Int(getInt64("track-list/count") ?? 0)
        for index in 0..<count where getInt64("track-list/\(index)/id") == id && getString("track-list/\(index)/type") == "sub" {
            if let filename = getString("track-list/\(index)/external-filename") {
                return canonicalExternalSubtitleSource(filename)
            }
            let language = getString("track-list/\(index)/lang") ?? ""
            let title = getString("track-list/\(index)/title") ?? ""
            let codec = getString("track-list/\(index)/codec") ?? ""
            let stream = getInt64("track-list/\(index)/ff-index") ?? id
            return "embedded:\(stream):\(language):\(title):\(codec)"
        }
        return "track:\(id)"
    }

    nonisolated func isImageTrack(_ id: Int64) -> Bool {
        let count = Int(getInt64("track-list/count") ?? 0)
        for index in 0..<count where getInt64("track-list/\(index)/id") == id && getString("track-list/\(index)/type") == "sub" {
            return Self.isImageSubtitleCodec(getString("track-list/\(index)/codec"))
        }
        return false
    }

    @discardableResult nonisolated func selectSlot(
        _ slot: MPVSubtitleSlot, id: Int64?, sourceID: String? = nil, original: Bool = false
    ) -> Bool {
        let previous = slotState(slot)
        let other = slotState(slot.other)
        let source = id.map { sourceID ?? sourceIdentity($0) }
        guard id == nil || (other.trackID != id && (source == nil || other.sourceID != source)) else { return false }
        guard id == nil || subtitleTrackIDs().contains(id!) else { return false }
        var target = previous
        target.trackID = id
        target.sourceID = source
        target.visible = id != nil
        target.usesOriginalStyle = original
        target.assOverride = original == previous.usesOriginalStyle ? previous.assOverride : (original ? .no : .strip)
        target = resolvedSubtitleStyleMode(target)
        if let old = previous.sourceID { subtitleSlots.delays[old] = previous.delay }
        target.delay = source.flatMap { subtitleSlots.delays[$0] } ?? 0
        guard applySlotState(target, slot: slot) else {
            _ = applySlotState(previous, slot: slot)
            return false
        }
        var published = target
        published.nativeVisible = getFlag(slot.visibilityProperty) ?? false
        published.isNative = slot == .secondary || !rendersDecodedSubtitleText
        let image = id.map { isImageTrack($0) } ?? false
        published.supportsTextStyle = id != nil && !image && !target.usesOriginalStyle
        published.updateShadowRadiusCapability(isImageSubtitle: image)
        subtitleSlots.states[slot] = target
        subtitleSlots.publish(published, slot: slot)
        return true
    }

    @discardableResult nonisolated func applySlotState(_ state: MPVSubtitleState, slot: MPVSubtitleSlot) -> Bool {
        let state = resolvedSubtitleStyleMode(state)
        guard mpv != nil else {
            subtitleSlots.states[slot] = state
            if slot == .primary { subtitleDelayValue = state.delay }
            return true
        }
        if slot == .primary {
            let previous = logicalSubtitleSelection()
            guard performSubtitleSelectionTransaction(previous: previous,
                targetUsesOriginalStyle: state.usesOriginalStyle, targetSubtitleID: state.trackID,
                targetVisibility: state.visible) else { return false }
            guard command("set", args: [slot.overrideProperty, state.assOverride.rawValue], checkForErrors: false) >= 0 else { return false }
            subtitleDelayValue = state.delay
        } else {
            let properties = [(slot.overrideProperty, state.assOverride.rawValue),
                              (slot.idProperty, state.trackID.map(String.init) ?? "no"),
                              (slot.visibilityProperty, state.visible ? "yes" : "no")]
            for (key, value) in properties {
                guard command("set", args: [key, value], checkForErrors: false) >= 0 else { return false }
            }
            guard getInt64(slot.idProperty).flatMap({ $0 > 0 ? $0 : nil }) == state.trackID else { return false }
        }
        for (key, value) in [(slot.delayProperty, state.delay), (slot.positionProperty, state.position)] {
            guard command("set", args: [key, String(value)], checkForErrors: false) >= 0 else { return false }
        }
        return true
    }

    nonisolated func cancelSlotLoads(_ slot: MPVSubtitleSlot) {
        for (userdata, load) in subtitleSlots.pending where load.slot == slot {
            if let mpv { mpv_abort_async_command(mpv, userdata) }
            subtitleSlots.pending.removeValue(forKey: userdata)
            subtitleSlots.canceled[userdata] = load
            finishSlotLoad(load, success: false, error: "字幕加载已取消")
        }
    }

    func loadSlotSubtitle(_ options: NSDictionary) {
        guard let request = options["requestID"] as? String,
              let url = options["url"] as? String, !url.isEmpty else { return }
        let slot = subtitleSlot(options)
        let original = boolValue(options["usesOriginalStyle"])
        let sourceID = options["sourceID"] as? String ?? canonicalExternalSubtitleSource(url)
        let session = currentBufferingSessionGeneration()
        queue.async { [weak self] in
            guard let self else { return }
            self.subtitleSlots.selectionRevision[slot, default: 0] &+= 1
            self.subtitleSlots.publishRevision(self.subtitleSlots.selectionRevision[slot, default: 0], slot: slot)
            self.cancelSlotLoads(slot)
            _ = self.logicalSubtitleSelection()
            let load = MPVSubtitleSlotRuntime.Load(requestID: request, slot: slot, url: url,
                sourceID: sourceID, original: original, before: self.subtitleTrackIDs(), session: session,
                generation: self.subtitleSlots.generation, previous: self.slotState(slot))
            guard !self.isStopped(), self.mpv != nil,
                  self.currentBufferingSessionGeneration() == session else {
                self.finishSlotLoad(load, success: false, error: "播放会话已结束")
                return
            }
            let other = self.slotState(slot.other)
            guard other.sourceID != sourceID,
                  !self.subtitleSlots.pending.values.contains(where: { $0.sourceID == sourceID }) else {
                self.finishSlotLoad(load, success: false, error: "该字幕已被另一路使用")
                return
            }
            let extensionName = URL(string: url)?.pathExtension.lowercased() ?? ""
            guard !["sup", "idx"].contains(extensionName) else {
                self.finishSlotLoad(load, success: false, error: "当前原版播放器不支持此外挂图片字幕")
                return
            }
            if let existing = self.subtitleSlots.externalSources.first(where: { $0.value == sourceID })?.key,
               self.subtitleTrackIDs().contains(existing) {
                let success = self.selectSlot(slot, id: existing, sourceID: sourceID, original: original)
                self.finishSlotLoad(load, success: success, error: success ? nil : "字幕选轨失败")
                return
            }
            let userdata = self.allocateMPVCommandUserdata()
            self.subtitleSlots.pending[userdata] = load
            self.subtitleSlots.publish(self.slotState(slot), slot: slot)
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.subtitleSlots.pending[userdata]?.requestID == request else { return }
                self.subtitleSlots.pending.removeValue(forKey: userdata)
                self.subtitleSlots.canceled[userdata] = load
                if let mpv = self.mpv { mpv_abort_async_command(mpv, userdata) }
                self.finishSlotLoad(load, success: false, error: "字幕加载超时")
            }
            let status = self.commandAsync("sub-add", args: [self.normalizedMPVSource(url), "auto"], replyUserdata: userdata)
            if status < 0 {
                self.subtitleSlots.pending.removeValue(forKey: userdata)
                self.finishSlotLoad(load, success: false, error: "字幕加载失败")
            }
        }
    }

    nonisolated func handleSlotSubtitleReply(userdata: UInt64, error: Int32) -> Bool {
        if let stale = subtitleSlots.canceled.removeValue(forKey: userdata) {
            if stale.session == currentBufferingSessionGeneration() {
                _ = restoreSubtitleSelection(logicalSubtitleSelection())
                if let id = externalSubtitleTrackID(source: normalizedMPVSource(stale.url), urlString: stale.url,
                    preferringIDsNotIn: stale.before), !stale.before.contains(id),
                   !MPVSubtitleSlot.allCases.contains(where: { slotState($0).trackID == id }) {
                    _ = command("sub-remove", args: [String(id)], checkForErrors: false)
                }
            }
            return true
        }
        guard let load = subtitleSlots.pending.removeValue(forKey: userdata) else { return false }
        guard load.session == currentBufferingSessionGeneration(), load.generation == subtitleSlots.generation,
              !isStopped() else { finishSlotLoad(load, success: false, error: "字幕请求已过期"); return true }
        let id = error >= 0 ? externalSubtitleTrackID(source: normalizedMPVSource(load.url), urlString: load.url,
            preferringIDsNotIn: load.before) : nil
        // sub-add auto 在首条字幕时也可能自动选择第一路，始终恢复已提交状态再显式选目标。
        _ = restoreSubtitleSelection(logicalSubtitleSelection())
        let success = id.map { selectSlot(load.slot, id: $0, sourceID: load.sourceID, original: load.original) } ?? false
        if success, let id {
            subtitleSlots.externalSources[id] = load.sourceID
            if subtitleSlots.restorationRequests.remove(load.requestID) != nil {
                var restored = load.previous
                restored.trackID = id
                if applySlotState(restored, slot: load.slot) { subtitleSlots.states[load.slot] = restored; subtitleSlots.publish(slotState(load.slot), slot: load.slot) }
            }
        }
        if !success, let id, !load.before.contains(id),
           !MPVSubtitleSlot.allCases.contains(where: { slotState($0).trackID == id }) {
            _ = command("sub-remove", args: [String(id)], checkForErrors: false)
        }
        refreshMediaTracksCache()
        finishSlotLoad(load, success: success, error: success ? nil : "无法加载或解码该字幕")
        return true
    }

    nonisolated func finishSlotLoad(_ load: MPVSubtitleSlotRuntime.Load, success: Bool, error: String?) {
        subtitleSlots.restorationRequests.remove(load.requestID)
        guard subtitleSlots.completedRequests.insert(load.requestID).inserted else { return }
        if load.session == currentBufferingSessionGeneration(), !isStopped() {
            subtitleSlots.publish(slotState(load.slot), slot: load.slot)
        }
        let slot = load.slot.rawValue
        let revision = subtitleSlots.selectionRevision[load.slot, default: 0]
        notifyOnMain {
            let accepted = success && self.currentBufferingSessionGeneration() == load.session && !self.isStopped()
                && self.subtitleSlots.revision(load.slot) == revision
            if accepted, load.slot == .primary { self.clearClientSubtitle() }
            NotificationCenter.default.post(name: MPVPlayerKitNotification.didLoadSubtitle, object: self,
                userInfo: ["requestID": load.requestID, "success": accepted, "slot": slot, "errorMessage": error ?? ""])
        }
    }
    nonisolated func notifySubtitleLoad(requestID: String, success: Bool) {
        let session = currentMPVPlaybackUpdateSourceSession() ?? queueConfigurationGeneration
        notifyOnMain {
            let accepted = success && self.currentBufferingSessionGeneration() == session && !self.isStopped()
            NotificationCenter.default.post(
                name: MPVPlayerKitNotification.didLoadSubtitle,
                object: self,
                userInfo: [
                    MPVPlayerKitNotificationKey.requestID: requestID,
                    MPVPlayerKitNotificationKey.success: accepted,
                ]
            )
        }
    }

}
