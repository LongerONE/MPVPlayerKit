import UIKit
import XCTest
@testable import MPVPlayerKit

final class MPVRepairRegressionTests: XCTestCase {
    @MainActor
    func testPiPRestoresOriginalSubregionConstraints() throws {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let view = MPVPlayerView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        let constraints = [view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 20),
                           view.topAnchor.constraint(equalTo: parent.topAnchor, constant: 100),
                           view.widthAnchor.constraint(equalToConstant: 300),
                           view.heightAnchor.constraint(equalToConstant: 200)]
        NSLayoutConstraint.activate(constraints)
        parent.layoutIfNeeded()
        let placement = try XCTUnwrap(MPVPictureInPictureViewPlacement(playerView: view))
        placement.movePlayer(to: UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 90)))
        XCTAssertTrue(constraints.allSatisfy { !$0.isActive })
        constraints[1].constant = 120
        placement.restorePlayer()
        XCTAssertTrue(constraints.allSatisfy(\.isActive))
        XCTAssertEqual(view.frame, CGRect(x: 20, y: 120, width: 300, height: 200))
        placement.tearDown()
    }

    @MainActor
    func testFallbackDoesNotWaitForBlockedMPVQueue() {
        let view = MPVPlayerView(frame: .zero)
        view.configure(["url": "file:///unused.mp4"])
        let gate = DispatchSemaphore(value: 0)
        view.queue.async { gate.wait() }
        defer { gate.signal() }
        view.replaceSetupProfiles([MPVSetupProfile(name: "first", options: [("hwdec", "yes")]),
                                   MPVSetupProfile(name: "next", options: [("hwdec", "no")])], activeIndex: 0)
        XCTAssertTrue(view.retryNextProfileAfterPlaybackFailure(errorCode: -1))
        view.stop()
    }

    @MainActor
    func testConfigurationMirrorAndQueuePreserveOrdering() async {
        let view = MPVPlayerView(frame: .zero)
        view.configure(["url": "file:///first.mp4", "cacheDuration": 30])
        view.configure(["url": "file:///second.mp4", "cacheDuration": 120])
        XCTAssertEqual(view.url?.lastPathComponent, "second.mp4")
        XCTAssertEqual(view.cacheConfiguration.duration, 120)
        let transfer = MPVPlayerViewWeakTransfer(view)
        let applied: String? = await withCheckedContinuation { continuation in
            view.queue.async { continuation.resume(returning: transfer.value?.url?.lastPathComponent) }
        }
        XCTAssertEqual(applied, "second.mp4")
        view.stop()
    }

    @MainActor
    func testAutoplayDoesNotOverridePauseOnSecondAppearance() {
        let controller = MPVQuickPlayerViewController(url: URL(fileURLWithPath: "/unused.mp4"))
        controller.loadViewIfNeeded()
        let gate = DispatchSemaphore(value: 0)
        controller.player.playbackView.queue.async { gate.wait() }
        defer { gate.signal() }
        controller.viewDidAppear(false)
        controller.player.pause()
        let pausedIntent = controller.player.playbackView.currentPlaybackIntentGeneration()
        controller.viewDidAppear(false)
        XCTAssertEqual(controller.player.playbackView.currentPlaybackIntentGeneration(), pausedIntent)
        controller.finishPlaybackSession()
    }

    @MainActor
    func testClosingCancelsLatePlaylistResolution() async {
        let item = SuspendedPlaylistItem()
        let controller = MPVQuickPlayerViewController(url: URL(fileURLWithPath: "/first.mp4"), autoplay: false)
        controller.playlistItems = [item]
        controller.switchPlaylistItem(to: 0)
        await item.waitUntilStarted()
        XCTAssertTrue(controller.isPlaylistSwitching)
        controller.finishPlaybackSession()
        item.resume()
        await Task.yield()
        XCTAssertNil(controller.playlistSwitchTask)
        XCTAssertTrue(controller.player.playbackView.isStopped())
        XCTAssertEqual(controller.player.playbackView.url?.lastPathComponent, "first.mp4")
    }

    @MainActor
    func testOldEndFileCannotStopNewPlayback() {
        let view = MPVPlayerView(frame: .zero)
        view.configure(["url": "file:///first.mp4"])
        let source = view.currentBufferingSessionGeneration()
        let intent = view.currentPlaybackIntentGeneration()
        view.configure(["url": "file:///second.mp4"])
        view.isPlaying = true
        view.handleEndFileOnMain(reason: nil, errorCode: -1, sourceSession: source, intent: intent)
        XCTAssertTrue(view.isPlaying)
        view.stop()
    }

    @MainActor
    func testOldTeardownCannotAdvanceNewConfigurationSession() async {
        let view = MPVPlayerView(frame: .zero)
        let old = view.currentBufferingSessionGeneration()
        _ = view.nextBufferingSessionGeneration()
        let current = view.currentBufferingSessionGeneration()
        let transfer = MPVPlayerViewWeakTransfer(view)
        let advanced: UInt64? = await withCheckedContinuation { continuation in
            view.queue.async {
                continuation.resume(returning: transfer.value?.advanceBufferingSession(ifCurrent: old))
            }
        }
        XCTAssertNil(advanced)
        XCTAssertEqual(view.currentBufferingSessionGeneration(), current)
    }

    @MainActor
    func testDiagnosticURLRemovesCredentialsPathsQueriesAndFragments() {
        let view = MPVPlayerView(frame: .zero)
        let url = URL(string: "https://test-user:test-password@example.com/private-token/video.mkv?Token=query-token#fragment-token")!
        let description = view.redactedURLDescription(url)
        for secret in ["test-user", "test-password", "private-token", "video.mkv", "query-token", "fragment-token"] {
            XCTAssertFalse(description.contains(secret))
        }
        XCTAssertTrue(description.contains("example.com"))
        XCTAssertTrue(description.contains("queryItems=1"))
    }

    @MainActor
    func testClientSubtitleVisibilityKeepsSelection() {
        let view = MPVPlayerView(frame: .zero)
        view.selectClientSubtitle(.init(format: .subRip, cues: [.init(startTime: 0, endTime: 10, text: "text")]))
        view.setSubtitleVisible(["visible": false])
        XCTAssertTrue(view.clientSubtitleController.hasSelection)
        XCTAssertFalse(view.clientSubtitleController.isVisible)
        view.setSubtitleVisible(["visible": true])
        XCTAssertTrue(view.clientSubtitleController.hasSelection)
        XCTAssertTrue(view.clientSubtitleController.isVisible)
    }
}

@MainActor
private final class SuspendedPlaylistItem: MPVQuickPlayerPlaylistItem {
    var title: String { "item" }
    private var continuation: CheckedContinuation<MPVQuickPlayerPlaybackResource, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    func resolvePlaybackResource() async throws -> MPVQuickPlayerPlaybackResource {
        await withCheckedContinuation {
            continuation = $0
            started = true
            startedContinuation?.resume()
            startedContinuation = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func resume() {
        continuation?.resume(returning: .init(url: URL(fileURLWithPath: "/late.mp4"), title: title))
        continuation = nil
    }
}
