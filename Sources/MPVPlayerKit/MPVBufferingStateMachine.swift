import Foundation

struct MPVBufferingSnapshot: Equatable, Sendable {
    enum PlaybackIntent: Equatable, Sendable {
        case playing
        case userPaused
        case stopped
    }

    var playbackIntent: PlaybackIntent = .stopped
    var fileLoaded = false
    var seeking = false
    var ended = false
    var failed = false
    var pausedForCache: Bool?
    var cacheBufferingState: Double?
    var coreIdle: Bool?
    var pause: Bool?
    var idleActive: Bool?
    var eofReached: Bool?

    var canUseCoreIdleFallback: Bool {
        playbackIntent == .playing
            && fileLoaded
            && seeking == false
            && ended == false
            && failed == false
            && pausedForCache != true
            && coreIdle == true
            && pause == false
            && idleActive == false
            && eofReached == false
    }
}

enum MPVBufferingInput: Sendable {
    case snapshot(MPVBufferingSnapshot)
    case playbackRestart
    case reset
    case fallbackElapsed
}

enum MPVBufferingState: Equatable, Sendable {
    case buffering
    case finished
}

enum MPVBufferingFallbackAction: Equatable, Sendable {
    case none
    case schedule
    case cancel
}

enum MPVBufferingReason: Equatable, Sendable {
    case pausedForCache
    case coreIdle
    case userPaused
    case seeking
    case lifecycle
    case playbackRestart
}

struct MPVBufferingDecision: Sendable {
    let state: MPVBufferingState
    let stateChanged: Bool
    let progress: Int
    let progressChanged: Bool
    let fallbackAction: MPVBufferingFallbackAction
    let reason: MPVBufferingReason?
}

struct MPVBufferingStateMachine: Sendable {
    private(set) var snapshot = MPVBufferingSnapshot()
    private(set) var state = MPVBufferingState.finished
    private(set) var progress = 100
    private(set) var reason: MPVBufferingReason?
    private var fallbackPending = false

    mutating func reduce(_ input: MPVBufferingInput) -> MPVBufferingDecision {
        let previousState = state
        let previousProgress = progress
        var fallbackAction = MPVBufferingFallbackAction.none

        switch input {
        case .snapshot(let newSnapshot):
            snapshot = newSnapshot
            fallbackAction = reduceSnapshot()
        case .fallbackElapsed:
            fallbackPending = false
            if snapshot.playbackIntent == .playing, snapshot.pausedForCache == true {
                enterBuffering(reason: .pausedForCache)
            } else if snapshot.canUseCoreIdleFallback {
                enterBuffering(reason: .coreIdle)
            } else {
                finishBuffering(reason: lifecycleReason(for: snapshot))
            }
        case .playbackRestart:
            fallbackAction = cancelFallbackIfNeeded()
            if snapshot.pausedForCache == true {
                // The cache signal is authoritative. A restart can be emitted
                // while mpv is still waiting for cache data, so do not hide the
                // spinner until paused-for-cache becomes false.
                enterBuffering(reason: .pausedForCache)
            } else {
                finishBuffering(reason: .playbackRestart)
            }
        case .reset:
            fallbackAction = cancelFallbackIfNeeded()
            snapshot = MPVBufferingSnapshot()
            finishBuffering(reason: .lifecycle)
        }

        return MPVBufferingDecision(
            state: state,
            stateChanged: previousState != state,
            progress: progress,
            progressChanged: previousProgress != progress,
            fallbackAction: fallbackAction,
            reason: reason
        )
    }

    private mutating func reduceSnapshot() -> MPVBufferingFallbackAction {
        if snapshot.playbackIntent != .playing || snapshot.ended || snapshot.failed {
            let action = cancelFallbackIfNeeded()
            finishBuffering(reason: lifecycleReason(for: snapshot))
            return action
        }

        if snapshot.pausedForCache == true {
            let action = cancelFallbackIfNeeded()
            enterBuffering(reason: .pausedForCache)
            return action
        }

        if state == .buffering, reason == .pausedForCache {
            finishBuffering(reason: lifecycleReason(for: snapshot))
        }

        if state == .buffering, reason == .coreIdle {
            if snapshot.canUseCoreIdleFallback {
                updateProgress()
                return .none
            }
            finishBuffering(reason: lifecycleReason(for: snapshot))
        }

        guard snapshot.canUseCoreIdleFallback else {
            return cancelFallbackIfNeeded()
        }
        guard state == .finished, fallbackPending == false else {
            return .none
        }
        fallbackPending = true
        return .schedule
    }

    private mutating func enterBuffering(reason: MPVBufferingReason) {
        state = .buffering
        self.reason = reason
        updateProgress()
    }

    private mutating func finishBuffering(reason: MPVBufferingReason?) {
        state = .finished
        progress = 100
        self.reason = reason
    }

    private mutating func updateProgress() {
        guard state == .buffering else {
            progress = 100
            return
        }
        guard let value = snapshot.cacheBufferingState, value.isFinite else {
            progress = 0
            return
        }
        progress = min(max(Int(value.rounded(.down)), 0), 100)
    }

    private mutating func cancelFallbackIfNeeded() -> MPVBufferingFallbackAction {
        guard fallbackPending else { return .none }
        fallbackPending = false
        return .cancel
    }

    private func lifecycleReason(for snapshot: MPVBufferingSnapshot) -> MPVBufferingReason {
        if snapshot.seeking { return .seeking }
        if snapshot.playbackIntent == .userPaused || snapshot.pause == true {
            return .userPaused
        }
        return .lifecycle
    }
}
