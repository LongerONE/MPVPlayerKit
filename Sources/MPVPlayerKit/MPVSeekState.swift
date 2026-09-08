import Foundation

struct MPVPlaybackTimeSnapshot: Sendable {
    let currentTime: TimeInterval
    let duration: TimeInterval?
}

struct MPVPlaybackUpdate: Sendable {
    let timeSnapshot: MPVPlaybackTimeSnapshot
    let bufferedProgress: Int?
    let bufferingSessionGeneration: UInt64
    let playbackIntentGeneration: UInt64
    let playbackPositionGeneration: UInt64
}

struct MPVSeekRequest: Equatable, Sendable {
    let requestID: String
    let targetTime: TimeInterval
    let autoPlay: Bool
    let playbackIntentGeneration: UInt64
    let playbackPositionGeneration: UInt64

    init(
        requestID: String,
        targetTime: TimeInterval,
        autoPlay: Bool,
        playbackIntentGeneration: UInt64,
        playbackPositionGeneration: UInt64 = 0
    ) {
        self.requestID = requestID
        self.targetTime = targetTime
        self.autoPlay = autoPlay
        self.playbackIntentGeneration = playbackIntentGeneration
        self.playbackPositionGeneration = playbackPositionGeneration
    }
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
