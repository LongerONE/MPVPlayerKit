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

    func testFixedSkipIntervalAlwaysUsesFifteenSeconds() {
        XCTAssertEqual(MPVSystemPlaybackControls.fixedSkipInterval(requestedInterval: 60), 15)
        XCTAssertEqual(MPVSystemPlaybackControls.fixedSkipInterval(requestedInterval: -2), -15)
        XCTAssertEqual(MPVSystemPlaybackControls.fixedSkipInterval(requestedInterval: 0), 0)
        XCTAssertEqual(MPVSystemPlaybackControls.fixedSkipInterval(requestedInterval: .infinity), 0)
    }

    func testPictureInPicturePlaybackTimeRangeRejectsInvalidDurations() {
        let valid = MPVSystemPlaybackControls.timeRange(duration: 90)
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.start, .zero)
        XCTAssertEqual(valid.duration, CMTime(seconds: 90, preferredTimescale: 600))
        XCTAssertEqual(MPVSystemPlaybackControls.timeRange(duration: 0), .invalid)
        XCTAssertEqual(MPVSystemPlaybackControls.timeRange(duration: .infinity), .invalid)
    }
}
