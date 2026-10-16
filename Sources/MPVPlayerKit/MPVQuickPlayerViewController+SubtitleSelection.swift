import Foundation

extension MPVQuickPlayerViewController {
    /// The track cache refreshes with playback time; retry only unfulfilled automatic choices.
    func automaticallySelectSubtitles() {
        guard !isPlaybackSessionClosed else { return }
        let tracks = player.tracks(ofType: .subtitle)
        guard !tracks.isEmpty else { return }
        // Release initial automatic slots together before assigning primary first.
        for slot in [MPVSubtitleSlot.primary, .secondary]
        where subtitleControls[slot]?.automatic == true && !subtitleManualSlots.contains(slot)
            && !subtitleAutomaticStarted.contains(slot) && subtitleRequests[slot] == nil {
            guard player.clearSubtitle(in: slot) else { return }
            subtitleAutomaticStarted.insert(slot)
        }
        for slot in [MPVSubtitleSlot.primary, .secondary] {
            guard let preference = subtitleControls[slot], preference.automatic,
                  !subtitleManualSlots.contains(slot), subtitleRequests[slot] == nil else { continue }
            let other = player.subtitleState(in: slot == .primary ? .secondary : .primary)
            let excluded = Set(other.trackID.flatMap(Int32.init(exactly:)).map { [$0] } ?? [])
            let candidate = MPVSubtitleAutoSelection.rank(
                tracks: tracks, language: preference.language, excludingTrackIDs: excluded
            ).first
            guard let candidate else {
                if subtitleAutomaticTrackIDs.removeValue(forKey: slot) != nil {
                    player.clearSubtitle(in: slot)
                }
                continue
            }
            let current = player.subtitleState(in: slot)
            guard current.trackID != Int64(candidate.id) else { continue }
            if player.select(track: candidate, in: slot, usesOriginalStyle: preference.usesOriginalStyle) {
                subtitleAutomaticTrackIDs[slot] = Int64(candidate.id)
                player.setSubtitlesVisible(true, in: slot)
            }
        }
    }

    func restartAutomaticSubtitleChoice(in slot: MPVSubtitleSlot) {
        // Explicit preference edits can replace automatic results, never this video's manual choice.
        guard !subtitleManualSlots.contains(slot) else { return }
        if subtitleAutomaticTrackIDs.removeValue(forKey: slot) != nil {
            player.clearSubtitle(in: slot)
        }
        subtitleAutomaticStarted.remove(slot)
    }

    func resetQuickPlayerSubtitleSession() {
        for slot in [MPVSubtitleSlot.primary, .secondary] {
            cancelExternalSubtitleLoad(in: slot)
        }
        subtitleManualSlots.removeAll()
        subtitleAutomaticTrackIDs.removeAll()
        subtitleAutomaticStarted.removeAll()
        subtitleDelay = 0
    }
}
