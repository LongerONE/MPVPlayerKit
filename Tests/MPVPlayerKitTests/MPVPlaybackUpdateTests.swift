import Foundation
import XCTest
import UIKit
@testable import MPVPlayerKit

private struct UnsafePlaybackTransfer<Value>: @unchecked Sendable {
    let value: Value
}

private final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [Notification.Name] = []

    func append(_ name: Notification.Name) {
        lock.lock()
        names.append(name)
        lock.unlock()
    }

    func snapshot() -> [Notification.Name] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
}

final class MPVPlaybackUpdateTests: XCTestCase {
    @MainActor
    func testMainAppliesPrecomputedPlaybackUpdateInNotificationOrder() {
        let playerView = MPVPlayerView(frame: .zero)
        playerView.systemPlaybackControlsEnabled = false
        let center = NotificationCenter.default
        let recorder = NotificationRecorder()
        let names = [
            MPVPlayerKitNotification.didUpdateTime,
            MPVPlayerKitNotification.didUpdateBufferedProgress,
            MPVPlayerKitNotification.didChangeState,
        ]
        let observers = names.map { name in
            center.addObserver(forName: name, object: playerView, queue: nil) { notification in
                recorder.append(notification.name)
            }
        }
        defer { observers.forEach { center.removeObserver($0) } }
        let update = MPVPlaybackUpdate(
            timeSnapshot: MPVPlaybackTimeSnapshot(currentTime: 12, duration: 90),
            bufferedProgress: 34,
            bufferingSessionGeneration: playerView.currentBufferingSessionGeneration(),
            playbackIntentGeneration: playerView.currentPlaybackIntentGeneration(),
            playbackPositionGeneration: playerView.currentPlaybackPositionGeneration()
        )

        playerView.applyMPVTimeUpdate(update)

        XCTAssertEqual(playerView.currentTime, 12)
        XCTAssertEqual(playerView.duration, 90)
        XCTAssertEqual(playerView.bufferedProgress?.intValue, 34)
        XCTAssertEqual(recorder.snapshot(), names)
    }

    @MainActor
    func testDestroyedHandleAndSeekUpdatesDoNotOverwriteCurrentTime() {
        let playerView = MPVPlayerView(frame: .zero)
        playerView.systemPlaybackControlsEnabled = false
        playerView.currentTime = 120
        let staleSessionUpdate = MPVPlaybackUpdate(
            timeSnapshot: MPVPlaybackTimeSnapshot(currentTime: 12, duration: 90),
            bufferedProgress: 34,
            bufferingSessionGeneration: playerView.currentBufferingSessionGeneration(),
            playbackIntentGeneration: playerView.currentPlaybackIntentGeneration(),
            playbackPositionGeneration: playerView.currentPlaybackPositionGeneration()
        )

        _ = playerView.nextBufferingSessionGeneration()
        playerView.applyMPVTimeUpdate(staleSessionUpdate)
        XCTAssertEqual(playerView.currentTime, 120)

        let stalePositionUpdate = MPVPlaybackUpdate(
            timeSnapshot: MPVPlaybackTimeSnapshot(currentTime: 24, duration: 90),
            bufferedProgress: 40,
            bufferingSessionGeneration: playerView.currentBufferingSessionGeneration(),
            playbackIntentGeneration: playerView.currentPlaybackIntentGeneration(),
            playbackPositionGeneration: playerView.currentPlaybackPositionGeneration()
        )
        _ = playerView.beginPlaybackPositionUpdate()
        playerView.currentTime = 240
        playerView.applyMPVTimeUpdate(stalePositionUpdate)

        XCTAssertEqual(playerView.currentTime, 240)
    }

    @MainActor
    func testOldHandleSourceIsRejectedWhenMainAdvancesSessionBeforeQueueSampling() async {
        let playerView = MPVPlayerView(frame: .zero)
        playerView.systemPlaybackControlsEnabled = false
        playerView.currentTime = 120
        let sourceSession = playerView.currentBufferingSessionGeneration()
        let transfer = UnsafePlaybackTransfer(value: playerView)

        await withCheckedContinuation { continuation in
            playerView.queue.async {
                transfer.value.bindMPVPlaybackUpdateSourceSession(sourceSession)
                continuation.resume()
            }
        }
        _ = playerView.nextBufferingSessionGeneration()

        let update: MPVPlaybackUpdate? = await withCheckedContinuation { continuation in
            playerView.queue.async {
                continuation.resume(returning: transfer.value.makeMPVPlaybackUpdate(
                    timeSnapshot: MPVPlaybackTimeSnapshot(currentTime: 12, duration: 90),
                    bufferedProgress: 34
                ))
            }
        }

        XCTAssertEqual(update?.bufferingSessionGeneration, sourceSession)
        if let update {
            playerView.applyMPVTimeUpdate(update)
        }
        XCTAssertEqual(playerView.currentTime, 120)
    }

    @MainActor
    func testMainInitiatedFallbackBindsNewSourceAfterQueuedTeardown() async {
        let playerView = MPVPlayerView(frame: .zero)
        let oldSourceSession = playerView.currentBufferingSessionGeneration()
        let transfer = UnsafePlaybackTransfer(value: playerView)

        await withCheckedContinuation { continuation in
            playerView.queue.async {
                transfer.value.bindMPVPlaybackUpdateSourceSession(oldSourceSession)
                continuation.resume()
            }
        }
        playerView.destroyMPVHandle(reason: "test-fallback", sendStopCommand: false)

        var newSourceSession: UInt64?
        playerView.performOnMPVQueueSync {
            let sourceSession = transfer.value.currentBufferingSessionGeneration()
            transfer.value.bindMPVPlaybackUpdateSourceSession(sourceSession)
            newSourceSession = sourceSession
        }

        var boundSourceSession: UInt64?
        playerView.performOnMPVQueueSync {
            boundSourceSession = transfer.value.currentMPVPlaybackUpdateSourceSession()
        }
        XCTAssertNotEqual(newSourceSession, oldSourceSession)
        XCTAssertEqual(boundSourceSession, newSourceSession)
    }

    @MainActor
    func testSeekFailureDoesNotRestoreOldSourceAfterSessionAdvances() async {
        let playerView = MPVPlayerView(frame: .zero)
        playerView.systemPlaybackControlsEnabled = false
        playerView.currentTime = 120
        let sourceSession = playerView.currentBufferingSessionGeneration()
        let positionGeneration = playerView.beginPlaybackPositionUpdate()
        let transfer = UnsafePlaybackTransfer(value: playerView)
        let request = MPVSeekRequest(
            requestID: "stale-source",
            targetTime: 12,
            autoPlay: false,
            playbackIntentGeneration: playerView.currentPlaybackIntentGeneration(),
            playbackPositionGeneration: positionGeneration
        )

        playerView.performOnMPVQueueSync {
            transfer.value.bindMPVPlaybackUpdateSourceSession(sourceSession)
            transfer.value.handleSeekReply(
                request: request,
                error: -1,
                recoverySnapshot: MPVPlaybackTimeSnapshot(currentTime: 12, duration: 90)
            )
        }
        _ = playerView.nextBufferingSessionGeneration()
        await Task.yield()

        XCTAssertEqual(playerView.currentTime, 120)
    }

    @MainActor
    func testCacheProgressUpdateStillAppliesDuringSeek() {
        let playerView = MPVPlayerView(frame: .zero)
        playerView.systemPlaybackControlsEnabled = false
        let update = MPVPlaybackUpdate(
            timeSnapshot: MPVPlaybackTimeSnapshot(currentTime: 12, duration: 90),
            bufferedProgress: 34,
            bufferingSessionGeneration: playerView.currentBufferingSessionGeneration(),
            playbackIntentGeneration: playerView.currentPlaybackIntentGeneration(),
            playbackPositionGeneration: playerView.currentPlaybackPositionGeneration()
        )

        _ = playerView.beginPlaybackPositionUpdate()
        playerView.applyMPVBufferedProgressUpdate(update)

        XCTAssertEqual(playerView.bufferedProgress?.intValue, 34)
        XCTAssertTrue(playerView.hasPendingPlaybackPositionUpdate())
    }

    @MainActor
    func testPlaybackUpdateCollectionRequiresMPVQueue() async {
        let playerView = MPVPlayerView(frame: .zero)
        let transfer = UnsafePlaybackTransfer(value: playerView)

        let result: (ranOnMPVQueue: Bool, hasNoHandleUpdate: Bool) = await withCheckedContinuation { continuation in
            playerView.queue.async {
                let update = transfer.value.readMPVPlaybackUpdate()
                continuation.resume(returning: (
                    DispatchQueue.getSpecific(key: transfer.value.queueSpecificKey) != nil,
                    update == nil
                ))
            }
        }

        XCTAssertTrue(result.ranOnMPVQueue)
        XCTAssertTrue(result.hasNoHandleUpdate)
    }
}
