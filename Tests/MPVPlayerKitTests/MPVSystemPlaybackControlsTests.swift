import CoreMedia
import XCTest
@testable import MPVPlayerKit

final class MPVSystemPlaybackControlsTests: XCTestCase {

    func testSeekTargetClampsFiniteDuration() {
        XCTAssertEqual(
            MPVSystemPlaybackControls.seekTarget(currentTime: 20, duration: 100, offset: 15),
            35
        )
        XCTAssertEqual(
            MPVSystemPlaybackControls.seekTarget(currentTime: 10, duration: 100, offset: -15),
            0
        )
        XCTAssertEqual(
            MPVSystemPlaybackControls.seekTarget(currentTime: 95, duration: 100, offset: 15),
            100
        )
    }

    func testSeekTargetAllowsUnknownDuration() {
        XCTAssertEqual(
            MPVSystemPlaybackControls.seekTarget(currentTime: 20, duration: 0, offset: 15),
            35
        )
        XCTAssertEqual(
            MPVSystemPlaybackControls.seekTarget(currentTime: 5, duration: .infinity, offset: -15),
            0
        )
    }

    func testSeekReplyAllowsAutoPlayOnlyAfterSuccessfulReply() {
        let request = MPVSeekRequest(
            requestID: "seek-1",
            targetTime: 120,
            autoPlay: true,
            playbackIntentGeneration: 0
        )

        XCTAssertEqual(
            MPVSeekReplyResolver.resolve(request: request, error: 0),
            MPVSeekReplyResolution(
                success: true,
                shouldAutoPlay: true,
                shouldRestoreTime: false
            )
        )
    }

    func testSeekReplyFailureRestoresTimeAndNeverAutoPlays() {
        let request = MPVSeekRequest(
            requestID: "seek-2",
            targetTime: 120,
            autoPlay: true,
            playbackIntentGeneration: 0
        )

        XCTAssertEqual(
            MPVSeekReplyResolver.resolve(request: request, error: -12),
            MPVSeekReplyResolution(
                success: false,
                shouldAutoPlay: false,
                shouldRestoreTime: true
            )
        )
    }

    func testUnknownSeekReplyDoesNotProduceAnAction() {
        XCTAssertNil(MPVSeekReplyResolver.resolve(request: nil, error: 0))
    }

    func testSeekReplyAutoPlayRequiresTheCurrentPlaybackIntent() {
        let request = MPVSeekRequest(
            requestID: "seek-3",
            targetTime: 120,
            autoPlay: true,
            playbackIntentGeneration: 4
        )
        let resolution = MPVSeekReplyResolver.resolve(request: request, error: 0)!

        XCTAssertTrue(
            MPVSeekReplyResolver.shouldAutoPlay(
                request: request,
                resolution: resolution,
                currentPlaybackIntentGeneration: 4
            )
        )
        XCTAssertFalse(
            MPVSeekReplyResolver.shouldAutoPlay(
                request: request,
                resolution: resolution,
                currentPlaybackIntentGeneration: 5
            )
        )
    }

    func testInitialPlaybackIntentCanAutoPlayAfterSuccessfulSeek() {
        let request = MPVSeekRequest(
            requestID: "initial-resume",
            targetTime: 120,
            autoPlay: true,
            playbackIntentGeneration: 0
        )
        let resolution = MPVSeekReplyResolver.resolve(request: request, error: 0)!

        XCTAssertTrue(
            MPVSeekReplyResolver.shouldAutoPlay(
                request: request,
                resolution: resolution,
                currentPlaybackIntentGeneration: 0
            )
        )
    }
}
