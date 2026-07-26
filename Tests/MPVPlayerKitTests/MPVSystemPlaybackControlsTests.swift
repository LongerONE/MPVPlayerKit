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
}
