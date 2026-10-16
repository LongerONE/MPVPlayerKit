import XCTest
import UIKit
@testable import MPVPlayerKit

final class MPVSubtitleSlotTests: XCTestCase {
    func testLanguageRankingRespectsScriptForcedDefaultAndStableOrder() throws {
        let tracks = try [
            track(1, language: "zh-Hant", name: "繁體", forced: false, isDefault: true),
            track(2, language: "zh-Hans", name: "简体 forced", forced: true),
            track(3, language: "zh-Hans", name: "简体 完整"),
            track(4, language: "zh-Hans", name: "简体 完整 default", isDefault: true),
            track(5, language: "zh-Hans", name: "简体 完整 default", isDefault: true)
        ]
        XCTAssertEqual(MPVSubtitleAutoSelection.rank(tracks: tracks, language: .simplifiedChinese).map(\.id), [4, 5, 3, 2])
        XCTAssertEqual(MPVSubtitleAutoSelection.rank(tracks: tracks, language: .traditionalChinese).map(\.id), [1])
        XCTAssertEqual(MPVSubtitleAutoSelection.rank(tracks: tracks, language: .simplifiedChinese, excludingTrackIDs: [4]).first?.id, 5)
        XCTAssertTrue(MPVSubtitleAutoSelection.rank(tracks: tracks, language: .english).isEmpty)
    }

    @MainActor func testDeferredControlsRemainIndependentAndFinite() async {
        let view = MPVPlayerView(frame: .zero)
        view.updateSubtitleControl(["slot": 1, "position": 170.0, "delay": 2.25, "assOverride": "force"])
        await withCheckedContinuation { continuation in
            view.queue.async { continuation.resume() }
        }
        let secondary = view.subtitleState(1)
        XCTAssertEqual(secondary["position"] as? Double, 150)
        XCTAssertEqual(secondary["delay"] as? Double, 2.25)
        XCTAssertEqual(secondary["assOverride"] as? String, "force")
        let noCue = view.subtitleTextSnapshot(1)
        XCTAssertTrue(noCue["startTime"] is NSNull)
        XCTAssertTrue(noCue["endTime"] is NSNull)
        let primary = view.subtitleState(0)
        XCTAssertEqual(primary["position"] as? Double, 100)
        XCTAssertEqual(primary["delay"] as? Double, 0)
        XCTAssertFalse(primary["visible"] as? Bool ?? true)
        view.stop()
    }

    @MainActor func testDefaultRendererTopPositionKeepsTextInsideBounds() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        let renderer = MPVDefaultSubtitleRenderer()
        renderer.view.frame = host.bounds
        host.addSubview(renderer.view)
        renderer.verticalPosition = 0
        renderer.render(MPVSubtitlePresentation(cues: [MPVSubtitleCue(startTime: 0, endTime: 5, text: "顶部字幕")], style: .defaultStyle))
        host.layoutIfNeeded()
        let label = try XCTUnwrap(renderer.view.subviews.first as? UILabel)
        XCTAssertGreaterThanOrEqual(label.frame.minY, 0)
        XCTAssertLessThanOrEqual(label.frame.maxY, host.bounds.height)
    }

    private func track(_ id: Int, language: String, name: String, forced: Bool = false,
                       isDefault: Bool = false) throws -> MPVMediaTrack {
        try XCTUnwrap(MPVMediaTrack(dictionary: ["trackID": id, "mpvType": "sub", "name": name,
            "languageCode": language, "codec": "subrip", "isForced": forced, "isDefault": isDefault]))
    }
}
