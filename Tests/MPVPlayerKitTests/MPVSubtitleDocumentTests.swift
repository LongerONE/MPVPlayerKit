import Foundation
import XCTest
@testable import MPVPlayerKit

final class MPVSubtitleDocumentTests: XCTestCase {
    func testWebVTTShortTimestampAndSettings() throws {
        let document = try decode("WEBVTT\n\n00:01.000 --> 00:02.500 align:start\n你好\n", ext: "vtt")
        XCTAssertEqual(document.cues, [MPVSubtitleCue(startTime: 1, endTime: 2.5, text: "你好")])
    }

    func testMalformedTimestampsAreRejected() {
        for timestamp in ["", "   ", "nan:00:01", "00:60:01", "00:00:60", "-1:00:01", "00::01", "inf:00:01"] {
            XCTAssertThrowsError(try decode("1\n\(timestamp) --> 00:00:02\ntext", ext: "srt"))
        }
    }

    func testSRTAndASSRemainSupported() throws {
        XCTAssertEqual(try decode("1\n01:02:03,250 --> 01:02:04,500\ntext", ext: "srt").cues.first?.startTime, 3723.25)
        let ass = "[Script Info]\n[Events]\nDialogue: 0,0:00:01.25,0:00:02.50,Default,,0,0,0,,text"
        XCTAssertEqual(try decode(ass, ext: "ass").cues.first?.startTime, 1.25)
    }

    private func decode(_ source: String, ext: String) throws -> MPVSubtitleDocument {
        try .decode(Data(source.utf8), sourceURL: URL(fileURLWithPath: "/subtitle.\(ext)"))
    }
}
