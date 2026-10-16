import XCTest
import UIKit
@testable import MPVPlayerKit

final class MPVSubtitleSlotTests: XCTestCase {
    @MainActor func testDocumentCapabilityDoesNotRequireActiveCueAndHonorsRenderer() throws {
        let document = try MPVSubtitleDocument.decode(Data("1\n00:01:00,000 --> 00:01:05,000\nLater cue".utf8),
            sourceURL: URL(fileURLWithPath: "/later.srt"))
        let view = MPVPlayerView(frame: .zero)
        defer { view.stop() }
        view.selectClientSubtitle(document)
        XCTAssertEqual(view.subtitleState(0)["shadowRadiusCapability"] as? String, "supported")
        view.useClientSubtitleRenderer(UnsupportedShadowRenderer())
        XCTAssertEqual(view.subtitleState(0)["shadowRadiusCapability"] as? String, "unsupportedRenderer")
        view.setSubtitleVisible(["slot": 0, "visible": false])
        XCTAssertEqual(view.subtitleState(0)["shadowRadiusCapability"] as? String, "inactive")
        view.clearClientSubtitle()
        XCTAssertEqual(view.subtitleState(0)["shadowRadiusCapability"] as? String, "inactive")
    }

    func testShadowRadiusAvailabilityExplainsOnlyActiveUnsupportedSlots() {
        let localized: (String) -> String = { MPVLocalization.string($0, localization: "zh-Hans") }
        let supported = MPVSubtitleShadowRadiusAvailability(capabilities: [.primary: .supported, .secondary: .inactive])
        XCTAssertTrue(supported.isEditable)
        XCTAssertNil(supported.explanation(localize: localized))
        let mixed = MPVSubtitleShadowRadiusAvailability(capabilities: [.primary: .supported, .secondary: .nativeRenderer])
        XCTAssertTrue(mixed.isEditable)
        XCTAssertEqual(mixed.explanation(localize: localized), "仅对第一字幕生效。\n第二字幕：MPV 原生渲染不支持单独调整阴影扩散半径。")
        let unsupported = MPVSubtitleShadowRadiusAvailability(capabilities: [.primary: .imageSubtitle, .secondary: .originalStyle])
        XCTAssertFalse(unsupported.isEditable)
        XCTAssertTrue(unsupported.explanation(localize: localized)?.contains("图片字幕") == true)
        XCTAssertTrue(unsupported.explanation(localize: localized)?.contains("原始样式") == true)
        let empty = MPVSubtitleShadowRadiusAvailability(capabilities: [.primary: .inactive, .secondary: .inactive])
        XCTAssertFalse(empty.isEditable)
        XCTAssertEqual(empty.explanation(localize: localized), "当前没有可调整阴影扩散半径的文本字幕。")
    }

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

@MainActor
private final class UnsupportedShadowRenderer: MPVSubtitleRenderer {
    let view = UIView()
    func render(_ presentation: MPVSubtitlePresentation) {}
    func clear() {}
}
