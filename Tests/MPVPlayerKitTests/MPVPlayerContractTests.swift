import XCTest
@testable import MPVPlayerKit

final class MPVPlayerContractTests: XCTestCase {
    func testPublicNotificationNamesMatchLegacyStrings() {
        XCTAssertEqual(
            MPVPlayerKitNotification.didChangeState.rawValue,
            "MPVPlayerViewDidChangeState"
        )
        XCTAssertEqual(
            MPVPlayerKitNotification.didUpdateTime.rawValue,
            "MPVPlayerViewDidUpdateTime"
        )
        XCTAssertEqual(
            MPVPlayerKitNotification.didUpdateBufferingProgress.rawValue,
            "MPVPlayerViewDidUpdateBufferingProgress"
        )
        XCTAssertEqual(
            MPVPlayerKitNotification.didUpdateBufferedProgress.rawValue,
            "MPVPlayerViewDidUpdateBufferedProgress"
        )
        XCTAssertEqual(
            MPVPlayerKitNotification.didUpdateDecoderMode.rawValue,
            "MPVPlayerViewDidUpdateDecoderMode"
        )
        XCTAssertEqual(
            MPVPlayerKitNotification.didLoadSubtitle.rawValue,
            "MPVPlayerViewDidLoadSubtitle"
        )
        XCTAssertEqual(
            MPVPlayerKitNotification.didCompleteSeek.rawValue,
            "MPVPlayerViewDidCompleteSeek"
        )
        XCTAssertEqual(
            MPVPlayerKitNotification.didChangePictureInPicture.rawValue,
            "MPVPlayerViewDidChangePictureInPicture"
        )
        XCTAssertEqual(MPVPlayerKitNotificationKey.state, "state")
        XCTAssertEqual(MPVPlayerKitNotificationKey.currentTime, "currentTime")
        XCTAssertEqual(MPVPlayerKitNotificationKey.duration, "duration")
        XCTAssertEqual(MPVPlayerKitNotificationKey.requestID, "requestID")
        XCTAssertEqual(MPVPlayerKitNotificationKey.success, "success")
    }

    func testMainActorPublicEntriesDoNotCallMpvPropertyHelpersDirectly() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let playbackSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MPVPlayerKit/MPVPlayerView+Playback.swift"),
            encoding: .utf8
        )
        let layoutSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MPVPlayerKit/MPVPlayerView+Layout.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(playbackSource.contains("queue.async { [weak self] in"))
        XCTAssertTrue(playbackSource.contains("self.setDouble(MPVProperty.speed, value)"))
        XCTAssertTrue(playbackSource.contains("cachedSubtitleTextValue()"))
        XCTAssertFalse(playbackSource.contains("setDouble(MPVProperty.speed, value)\n        requestDiagnosticSnapshot"))
        XCTAssertTrue(layoutSource.contains("applyContentModeOnMPVQueue"))
        XCTAssertTrue(layoutSource.contains("dispatchPrecondition(condition: .onQueue(queue))"))
    }

    func testTimeTimerOperationsRequireMPVQueue() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let layoutSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MPVPlayerKit/MPVPlayerView+Layout.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(layoutSource.contains("nonisolated func startTimeTimer()"))
        XCTAssertTrue(layoutSource.contains("nonisolated func stopTimeTimer()"))
        XCTAssertTrue(layoutSource.contains("requestStopTimeTimer(generation: UInt64)"))
        XCTAssertTrue(layoutSource.contains("dispatchPrecondition(condition: .onQueue(queue))"))
    }

    @MainActor
    func testStartPictureInPictureSkipsSystemControlsWhenDisabled() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controlSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/MPVPlayerKit/MPVPlayerView+PictureInPictureControl.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            controlSource.contains("if systemPlaybackControlsEnabled"),
            "PiP start must respect systemPlaybackControlsEnabled"
        )
        XCTAssertTrue(
            controlSource.contains("activateSystemPlaybackControlsForPictureInPicture()"),
            "enabled=true path still activates system controls"
        )
    }

    @MainActor
    func testSystemPlaybackControlsReactivatesWhenEnabledWhilePlaying() {
        let playerView = MPVPlayerView(frame: .zero)
        playerView.systemPlaybackControlsEnabled = false
        playerView.isPlaying = true
        playerView.systemPlaybackControlsEnabled = true
        XCTAssertTrue(playerView.systemPlaybackControlsEnabled)
    }
}
