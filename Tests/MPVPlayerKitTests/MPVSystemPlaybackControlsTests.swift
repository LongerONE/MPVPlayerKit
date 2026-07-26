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

    func testResolvedSkipIntervalKeepsTheRequestedAmount() {
        XCTAssertEqual(MPVSystemPlaybackControls.resolvedSkipInterval(requestedInterval: 10), 10)
        XCTAssertEqual(MPVSystemPlaybackControls.resolvedSkipInterval(requestedInterval: -10), -10)
        XCTAssertEqual(MPVSystemPlaybackControls.resolvedSkipInterval(requestedInterval: 60), 60)
    }

    func testResolvedSkipIntervalClampsUnusableAmounts() {
        XCTAssertEqual(MPVSystemPlaybackControls.resolvedSkipInterval(requestedInterval: 0.2), 1)
        XCTAssertEqual(MPVSystemPlaybackControls.resolvedSkipInterval(requestedInterval: -0.2), -1)
        XCTAssertEqual(MPVSystemPlaybackControls.resolvedSkipInterval(requestedInterval: 9000), 600)
        XCTAssertEqual(MPVSystemPlaybackControls.resolvedSkipInterval(requestedInterval: 0), 0)
        XCTAssertEqual(
            MPVSystemPlaybackControls.resolvedSkipInterval(requestedInterval: .infinity),
            0
        )
    }

    func testPictureInPicturePlaybackTimeRangeUsesFiniteDuration() {
        let valid = MPVSystemPlaybackControls.timeRange(duration: 90)
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.start, .zero)
        XCTAssertEqual(valid.duration, CMTime(seconds: 90, preferredTimescale: 600))
    }

    func testPictureInPicturePlaybackTimeRangeReportsUnknownDurationAsLive() {
        // AVKit hides the Picture in Picture progress for an invalid range and
        // expects an infinite range for live content.
        XCTAssertEqual(
            MPVSystemPlaybackControls.timeRange(duration: 0),
            MPVSystemPlaybackControls.liveTimeRange
        )
        XCTAssertEqual(
            MPVSystemPlaybackControls.timeRange(duration: .infinity),
            MPVSystemPlaybackControls.liveTimeRange
        )
        XCTAssertEqual(MPVSystemPlaybackControls.liveTimeRange.start, .negativeInfinity)
        XCTAssertEqual(MPVSystemPlaybackControls.liveTimeRange.duration, .positiveInfinity)
    }
}
