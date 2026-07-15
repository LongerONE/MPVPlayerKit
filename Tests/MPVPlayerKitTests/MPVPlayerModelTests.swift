import XCTest
@testable import MPVPlayerKit

final class MPVPlayerModelTests: XCTestCase {
    func testConfigurationCreatesBridgeValues() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let configuration = MPVPlayerConfiguration(
            url: url,
            headers: ["Authorization": "Bearer token"],
            userAgent: "Tests/1.0",
            forceSoftwareDecode: true,
            isDolbyVisionPlayback: true,
            videoQuality: .highQuality,
            debandEnabled: true,
            smoothPlaybackEnabled: true
        )

        let values = configuration.bridgeDictionary

        XCTAssertEqual(values["url"] as? String, url.absoluteString)
        XCTAssertEqual(values["headers"] as? [String: String], ["Authorization": "Bearer token"])
        XCTAssertEqual(values["userAgent"] as? String, "Tests/1.0")
        XCTAssertEqual((values["forceSoftwareDecode"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values["isDolbyVisionPlayback"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values["videoQuality"] as? NSNumber)?.intValue, MPVVideoQuality.highQuality.rawValue)
        XCTAssertEqual((values["debandEnabled"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values["smoothPlaybackEnabled"] as? NSNumber)?.boolValue, true)
    }

    func testMediaTrackParsesBridgeDictionary() throws {
        let track = try XCTUnwrap(MPVMediaTrack(dictionary: [
            "trackID": NSNumber(value: 7),
            "mpvType": "audio",
            "name": "English · AAC",
            "languageCode": "eng",
            "codec": "aac",
            "bitRate": NSNumber(value: 256_000),
            "isEnabled": NSNumber(value: true),
            "isImageSubtitle": NSNumber(value: false),
        ] as NSDictionary))

        XCTAssertEqual(track.id, 7)
        XCTAssertEqual(track.type, .audio)
        XCTAssertEqual(track.name, "English · AAC")
        XCTAssertEqual(track.languageCode, "eng")
        XCTAssertEqual(track.codec, "aac")
        XCTAssertEqual(track.bitRate, 256_000)
        XCTAssertTrue(track.isSelected)
        XCTAssertFalse(track.isImageSubtitle)
    }

    func testMediaTrackRejectsUnknownTrackType() {
        let track = MPVMediaTrack(dictionary: [
            "trackID": NSNumber(value: 1),
            "mpvType": "unknown",
        ] as NSDictionary)

        XCTAssertNil(track)
    }

    func testQuickPlayerSeekGestureUsesStableDurationRelativeSensitivity() {
        XCTAssertEqual(
            MPVQuickPlayerViewController.seekTimeDelta(
                translationX: 160,
                viewWidth: 320,
                duration: 7_200
            ),
            300,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MPVQuickPlayerViewController.seekTimeDelta(
                translationX: -160,
                viewWidth: 320,
                duration: 300
            ),
            -30,
            accuracy: 0.001
        )
    }

    func testQuickPlayerVerticalGestureClampsToValidSystemRange() {
        XCTAssertEqual(
            MPVQuickPlayerViewController.verticalValue(
                startValue: 0.5,
                translationY: -200,
                viewHeight: 400
            ),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MPVQuickPlayerViewController.verticalValue(
                startValue: 0.5,
                translationY: 200,
                viewHeight: 400
            ),
            0,
            accuracy: 0.001
        )
    }

    func testQuickPlayerOnlyShowsLoadingIndicatorWhileBuffering() {
        XCTAssertTrue(MPVQuickPlayerViewController.shouldShowLoading(for: .buffering))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .readyToPlay))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .bufferFinished))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .paused))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .playedToTheEnd))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .error))
    }
}
