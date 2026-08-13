import Foundation

struct MPVPlaybackTimeSnapshot: Sendable {
    let currentTime: TimeInterval
    let duration: TimeInterval?
}

struct MPVSeekRequest: Equatable, Sendable {
    let requestID: String
    let targetTime: TimeInterval
    let autoPlay: Bool
    let playbackIntentGeneration: UInt64
}

struct MPVSeekReplyResolution: Equatable, Sendable {
    let success: Bool
    let shouldAutoPlay: Bool
    let shouldRestoreTime: Bool
}

enum MPVSeekReplyResolver {
    static func resolve(
        request: MPVSeekRequest?,
        error: Int32
    ) -> MPVSeekReplyResolution? {
        guard let request else { return nil }
        let success = error >= 0
        return MPVSeekReplyResolution(
            success: success,
            shouldAutoPlay: success && request.autoPlay,
            shouldRestoreTime: success == false
        )
    }

    static func shouldAutoPlay(
        request: MPVSeekRequest,
        resolution: MPVSeekReplyResolution,
        currentPlaybackIntentGeneration: UInt64
    ) -> Bool {
        resolution.shouldAutoPlay
            && request.playbackIntentGeneration == currentPlaybackIntentGeneration
    }
}
