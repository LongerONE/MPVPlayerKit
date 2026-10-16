import Foundation

extension MPVPlayerView {
    nonisolated static func isASSSubtitleCodec(_ codec: String?) -> Bool {
        guard let codec else { return false }
        return ["ass", "ssa", "substation_alpha"].contains(codec.lowercased().replacingOccurrences(of: "-", with: "_"))
    }

    /// 只计算生效状态，不读写宿主保存的 ASS 偏好。
    nonisolated func resolvedSubtitleStyleMode(_ input: MPVSubtitleState) -> MPVSubtitleState {
        var state = input
        state.supportsASSMode = false
        guard let id = state.trackID, let codec = subtitleTrackCodec(id) else { return state }
        state.supportsASSMode = Self.isASSSubtitleCodec(codec)
        if !state.supportsASSMode, Self.supportsDecodedSubtitleText(codec: codec, usesOriginalStyle: false) {
            state.usesOriginalStyle = false
            state.assOverride = .strip
        }
        return state
    }

    nonisolated func subtitleTrackCodec(_ id: Int64) -> String? {
        let count = Int(getInt64("track-list/count") ?? 0)
        for index in 0..<count where getInt64("track-list/\(index)/id") == id
            && getString("track-list/\(index)/type") == "sub" {
            return getString("track-list/\(index)/codec")
        }
        return nil
    }
}
