import XCTest
@testable import MPVPlayerKit

final class MPVBufferingStateMachineTests: XCTestCase {
    func testPausedForCacheIsImmediateAndUsesMpvProgress() {
        var machine = MPVBufferingStateMachine()
        var snapshot = playingSnapshot()
        snapshot.pausedForCache = true

        var decision = machine.reduce(.snapshot(snapshot))

        XCTAssertEqual(decision.state, .buffering)
        XCTAssertTrue(decision.stateChanged)
        XCTAssertEqual(decision.progress, 0)
        XCTAssertTrue(decision.progressChanged)
        XCTAssertEqual(decision.fallbackAction, .none)

        snapshot.cacheBufferingState = 42.9
        decision = machine.reduce(.snapshot(snapshot))

        XCTAssertEqual(decision.state, .buffering)
        XCTAssertFalse(decision.stateChanged)
        XCTAssertEqual(decision.progress, 42)
        XCTAssertTrue(decision.progressChanged)
    }

    func testCachePauseFinishesImmediatelyWhenMpvReportsResume() {
        var machine = MPVBufferingStateMachine()
        var snapshot = playingSnapshot()
        snapshot.pausedForCache = true
        _ = machine.reduce(.snapshot(snapshot))

        snapshot.pausedForCache = false
        let decision = machine.reduce(.snapshot(snapshot))

        XCTAssertEqual(decision.state, .finished)
        XCTAssertTrue(decision.stateChanged)
        XCTAssertEqual(decision.progress, 100)
        XCTAssertEqual(decision.reason, .lifecycle)
    }

    func testCoreIdleFallbackRequiresAllPlaybackGuards() {
        var machine = MPVBufferingStateMachine()
        var snapshot = playingSnapshot()
        snapshot.coreIdle = true

        var decision = machine.reduce(.snapshot(snapshot))
        XCTAssertEqual(decision.fallbackAction, .schedule)
        XCTAssertEqual(decision.state, .finished)

        decision = machine.reduce(.fallbackElapsed)
        XCTAssertEqual(decision.state, .buffering)
        XCTAssertTrue(decision.stateChanged)
        XCTAssertEqual(decision.reason, .coreIdle)

        snapshot.pause = true
        decision = machine.reduce(.snapshot(snapshot))
        XCTAssertEqual(decision.state, .finished)
        XCTAssertTrue(decision.stateChanged)
        XCTAssertEqual(decision.reason, .userPaused)
    }

    func testCoreIdleShortJitterCancelsFallbackWithoutSpinner() {
        var machine = MPVBufferingStateMachine()
        var snapshot = playingSnapshot()
        snapshot.coreIdle = true
        _ = machine.reduce(.snapshot(snapshot))

        snapshot.coreIdle = false
        let decision = machine.reduce(.snapshot(snapshot))

        XCTAssertEqual(decision.fallbackAction, .cancel)
        XCTAssertEqual(decision.state, .finished)
        XCTAssertFalse(decision.stateChanged)
    }

    func testSeekingCancelsFallbackAndNeverShowsSpinner() {
        var machine = MPVBufferingStateMachine()
        var snapshot = playingSnapshot()
        snapshot.coreIdle = true
        _ = machine.reduce(.snapshot(snapshot))

        snapshot.seeking = true
        let decision = machine.reduce(.snapshot(snapshot))

        XCTAssertEqual(decision.fallbackAction, .cancel)
        XCTAssertEqual(decision.state, .finished)
        XCTAssertEqual(decision.reason, .seeking)
    }

    func testPlaybackRestartClearsBufferingIdempotently() {
        var machine = MPVBufferingStateMachine()
        var snapshot = playingSnapshot()
        snapshot.coreIdle = true
        _ = machine.reduce(.snapshot(snapshot))
        _ = machine.reduce(.fallbackElapsed)

        var decision = machine.reduce(.playbackRestart)
        XCTAssertEqual(decision.state, .finished)
        XCTAssertTrue(decision.stateChanged)
        XCTAssertEqual(decision.reason, .playbackRestart)

        decision = machine.reduce(.playbackRestart)
        XCTAssertEqual(decision.state, .finished)
        XCTAssertFalse(decision.stateChanged)
        XCTAssertEqual(decision.reason, .playbackRestart)
    }

    func testPlaybackRestartKeepsAuthoritativeCacheBuffering() {
        var machine = MPVBufferingStateMachine()
        var snapshot = playingSnapshot()
        snapshot.pausedForCache = true
        _ = machine.reduce(.snapshot(snapshot))

        let decision = machine.reduce(.playbackRestart)

        XCTAssertEqual(decision.state, .buffering)
        XCTAssertFalse(decision.stateChanged)
        XCTAssertEqual(decision.reason, .pausedForCache)
    }

    func testInvalidOrUnavailableProgressFallsBackToIndeterminateZero() {
        var machine = MPVBufferingStateMachine()
        var snapshot = playingSnapshot()
        snapshot.pausedForCache = true
        snapshot.cacheBufferingState = 200

        var decision = machine.reduce(.snapshot(snapshot))
        XCTAssertEqual(decision.progress, 100)

        snapshot.cacheBufferingState = .nan
        decision = machine.reduce(.snapshot(snapshot))
        XCTAssertEqual(decision.progress, 0)
        XCTAssertTrue(decision.progressChanged)
    }

    func testStoppedAndUnloadedSnapshotsDoNotScheduleFallback() {
        var machine = MPVBufferingStateMachine()
        var snapshot = playingSnapshot()
        snapshot.coreIdle = true
        snapshot.fileLoaded = false

        var decision = machine.reduce(.snapshot(snapshot))
        XCTAssertEqual(decision.fallbackAction, .none)
        XCTAssertEqual(decision.state, .finished)

        snapshot.fileLoaded = true
        snapshot.playbackIntent = .stopped
        decision = machine.reduce(.snapshot(snapshot))
        XCTAssertEqual(decision.fallbackAction, .none)
        XCTAssertEqual(decision.state, .finished)
    }

    private func playingSnapshot() -> MPVBufferingSnapshot {
        var snapshot = MPVBufferingSnapshot()
        snapshot.playbackIntent = .playing
        snapshot.fileLoaded = true
        snapshot.pause = false
        snapshot.idleActive = false
        snapshot.eofReached = false
        return snapshot
    }
}
