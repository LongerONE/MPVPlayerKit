import XCTest
import UIKit
@testable import MPVPlayerKit

@MainActor
final class MPVSubtitleLayoutIntegrationTests: XCTestCase {
    private var player: MPVPlayer?
    private var window: UIWindow?

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "SubtitleFixtures"))
    }

    private func start() async throws -> MPVPlayer {
        let value = MPVPlayer(configuration: .init(url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { host.windowScene = scene }
        host.rootViewController = UIViewController()
        value.playbackView.frame = host.bounds
        host.rootViewController?.view.addSubview(value.playbackView)
        host.makeKeyAndVisible()
        window = host
        player = value
        value.play()
        try await wait("真实引擎启动") { value.currentTime > 0 }
        value.pause()
        return value
    }

    private func cleanUp() {
        player?.stop()
        player = nil
        window?.isHidden = true
        window = nil
    }

    private func wait(_ reason: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<160 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("等待超时：\(reason)")
        throw LayoutError.timeout
    }
    private enum LayoutError: Error { case timeout }

    private func load(_ name: String, in slot: MPVSubtitleSlot, on value: MPVPlayer, original: Bool = false) async throws {
        var result: Bool?
        value.loadExternalSubtitle(from: try fixture(name), in: slot, usesOriginalStyle: original) { result = $0 }
        try await wait("加载 \(name)") { result != nil }
        XCTAssertEqual(result, true)
    }

    private func labels(_ value: MPVPlayer) throws -> (UILabel, UILabel) {
        (try XCTUnwrap(value.playbackView.clientSubtitleRenderer.view.subviews.first as? UILabel),
         try XCTUnwrap(value.playbackView.secondarySubtitleRenderer.view.subviews.first as? UILabel))
    }

    private func assertStacked(_ value: MPVPlayer, file: StaticString = #filePath, line: UInt = #line) throws {
        value.playbackView.layoutIfNeeded()
        let (first, second) = try labels(value)
        XCTAssertLessThanOrEqual(first.frame.maxY + 1, second.frame.minY, file: file, line: line)
        XCTAssertLessThan(second.frame.minY - first.frame.maxY, 10, file: file, line: line)
        XCTAssertGreaterThanOrEqual(first.frame.minY, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(second.frame.maxY, value.playbackView.bounds.height, file: file, line: line)
    }

    private func attach(_ name: String, value: MPVPlayer) {
        value.playbackView.layoutIfNeeded()
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: value.playbackView.bounds).image {
            _ in value.playbackView.drawHierarchy(in: value.playbackView.bounds, afterScreenUpdates: true)
        })
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMultilineGroupingDelayHidingAndPositionRestoration() async throws {
        defer { cleanUp() }
        let value = try await start()
        value.setSubtitlePosition(100, in: .primary)
        value.setSubtitlePosition(20, in: .secondary)
        try await load("multiline.srt", in: .primary, on: value)
        try await load("secondary.vtt", in: .secondary, on: value)
        XCTAssertTrue(value.seek(to: 2))
        let (first, second) = try labels(value)
        try await wait("两路多行台词") { first.text?.contains("PRIMARY_LINE_THREE") == true && second.text?.contains("SECONDARY_ONE") == true }
        value.playbackView.layoutIfNeeded()
        let independentSecondY = second.frame.minY
        let groupBottom = first.frame.maxY
        value.subtitleLayoutMode = .stacked
        try assertStacked(value)
        XCTAssertEqual(second.frame.maxY, groupBottom, accuracy: 1)
        attach("组合布局-第一路三行-第二路跟随", value: value)
        value.setSubtitlesVisible(false, in: .primary)
        try await wait("隐藏第一路不占空行") { first.attributedText == nil }
        value.playbackView.layoutIfNeeded()
        XCTAssertEqual(second.frame.maxY, groupBottom, accuracy: 1)
        value.setSubtitlesVisible(true, in: .primary)
        value.setSubtitleDelay(2, in: .secondary)
        XCTAssertTrue(value.seek(to: 5))
        try await wait("组合布局保留两路独立正延迟") { first.text == "MULTI_NEXT" && second.text == "SECONDARY_ONE" }
        try assertStacked(value)
        value.setSubtitleDelay(-1, in: .secondary)
        XCTAssertTrue(value.seek(to: 3.5))
        try await wait("组合布局保留负延迟") { first.text?.contains("PRIMARY_LINE_THREE") == true && second.text == "SECONDARY_TWO" }
        for _ in 0..<8 { value.subtitleLayoutMode = .independent; value.subtitleLayoutMode = .stacked }
        try assertStacked(value)
        value.subtitleLayoutMode = .independent
        value.playbackView.layoutIfNeeded()
        XCTAssertEqual(second.frame.minY, independentSecondY, accuracy: 1)
        XCTAssertEqual(value.subtitleState(in: .secondary).position, 20)
        XCTAssertEqual(value.subtitleState(in: .primary).position, 100)
        attach("切回独立布局-原位置恢复", value: value)
    }

    func testOriginalASSFallbackHiddenLaneAndCustomRenderer() async throws {
        defer { cleanUp() }
        let value = try await start()
        try await load("primary.srt", in: .primary, on: value)
        try await load("original.ass", in: .secondary, on: value, original: true)
        value.subtitleLayoutMode = .stacked
        XCTAssertEqual(value.subtitleLayoutStatus.fallbackReason, .originalStyle)
        XCTAssertEqual(value.subtitleLayoutStatus.effectiveMode, .independent)
        XCTAssertTrue(value.subtitleState(in: .secondary).usesOriginalStyle)
        value.setSubtitlesVisible(false, in: .secondary)
        try await wait("隐藏不兼容路后允许组合") { value.subtitleLayoutStatus.effectiveMode == .stacked }
        value.setSubtitleUsesOriginalStyle(false, in: .secondary)
        value.setSubtitlesVisible(true, in: .secondary)
        XCTAssertTrue(value.seek(to: 2))
        let (first, second) = try labels(value)
        try await wait("ASS 播放器样式自动恢复组合") { first.text == "PRIMARY_ALPHA" && second.text == "ASS_ONE" }
        XCTAssertEqual(value.subtitleLayoutMode, .stacked)
        XCTAssertNil(value.subtitleLayoutStatus.fallbackReason)
        try assertStacked(value)
        value.useClientSubtitleRenderer(CustomRenderer())
        XCTAssertEqual(value.subtitleLayoutStatus.fallbackReason, .unsupportedRenderer)
        value.useClientSubtitleRenderer(MPVDefaultSubtitleRenderer())
        XCTAssertNil(value.subtitleLayoutStatus.fallbackReason)
        var image = value.playbackView.subtitleSlots.snapshot(.secondary)
        image.isNative = true
        image.shadowRadiusCapability = .imageSubtitle
        image.usesOriginalStyle = true
        value.playbackView.subtitleSlots.publish(image, slot: .secondary)
        XCTAssertEqual(value.subtitleLayoutStatus.fallbackReason, .imageSubtitle, "位图兼容性纯状态断言")
    }

    func testRebuildRestoresGroupAndIndependentTiming() async throws {
        defer { cleanUp() }
        let old = try await start()
        try await load("primary.srt", in: .primary, on: old)
        try await load("secondary.vtt", in: .secondary, on: old)
        old.setSubtitlePosition(70, in: .primary)
        old.setSubtitlePosition(15, in: .secondary)
        old.setSubtitleDelay(-1, in: .primary)
        old.setSubtitleDelay(2, in: .secondary)
        old.subtitleLayoutMode = .stacked
        try await wait("重建前设置完成") { old.subtitleState(in: .secondary).delay == 2 }
        let snapshot = old.subtitleSessionSnapshot()
        old.stop()
        old.playbackView.removeFromSuperview()
        let rebuilt = MPVPlayer(configuration: .init(url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        player = rebuilt
        rebuilt.playbackView.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        window?.rootViewController?.view.addSubview(rebuilt.playbackView)
        rebuilt.restoreSubtitleSession(snapshot)
        rebuilt.play()
        try await wait("两路实际重建恢复") { MPVSubtitleSlot.allCases.allSatisfy { rebuilt.subtitleState(in: $0).trackID != nil } }
        rebuilt.pause()
        XCTAssertTrue(rebuilt.seek(to: 5))
        let (first, second) = try labels(rebuilt)
        try await wait("重建后组合及正负延迟") { first.text == "PRIMARY_BRAVO" && second.text == "SECONDARY_ONE" }
        XCTAssertEqual(rebuilt.subtitleLayoutMode, .stacked)
        XCTAssertEqual(rebuilt.subtitleState(in: .primary).position, 70)
        XCTAssertEqual(rebuilt.subtitleState(in: .secondary).position, 15)
        try assertStacked(rebuilt)
    }

    func testOversizedDocumentFallbackDoesNotChangeStyle() async throws {
        defer { cleanUp() }
        let value = try await start()
        value.updateSubtitleStyle(.init(fontSize: 64))
        value.subtitleLayoutMode = .stacked
        let lines = Array(repeating: "LONG_SUBTITLE", count: 50).joined(separator: "\n")
        let document = try MPVSubtitleDocument.decode(Data("1\n00:00:00,000 --> 00:00:12,000\n\(lines)".utf8), sourceURL: URL(fileURLWithPath: "/long.srt"))
        value.selectClientSubtitle(document)
        XCTAssertEqual(value.subtitleLayoutStatus.fallbackReason, .insufficientSpace)
        XCTAssertEqual(value.playbackView.clientSubtitleController.style.fontSize, 64)
        let short = try MPVSubtitleDocument.decode(Data("1\n00:00:00,000 --> 00:00:12,000\nSHORT".utf8), sourceURL: URL(fileURLWithPath: "/short.srt"))
        value.selectClientSubtitle(short)
        XCTAssertEqual(value.subtitleLayoutStatus.effectiveMode, .stacked)
    }

    func testQuickPlayerLayoutChoiceAutomaticSelectionAndPreferences() async throws {
        let keys = ["MPVQuickPlayer.subtitle.0", "MPVQuickPlayer.subtitle.1", "MPVQuickPlayer.subtitleLayoutMode"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            cleanUp()
            for (index, key) in keys.enumerated() { UserDefaults.standard.set(saved[index], forKey: key) }
        }
        MPVQuickPlayerSubtitlePreferences.layoutMode = .independent
        MPVQuickPlayerSubtitlePreferences.save(.init(position: 100, usesOriginalStyle: true, automatic: true, language: .english), in: .primary)
        MPVQuickPlayerSubtitlePreferences.save(.init(position: 15, usesOriginalStyle: false, automatic: true, language: .simplifiedChinese), in: .secondary)
        let before = (0...1).map { UserDefaults.standard.dictionary(forKey: "MPVQuickPlayer.subtitle.\($0)") as NSDictionary? }
        let quick = MPVQuickPlayerViewController(configuration: .init(url: try fixture("style-modes.mkv"), forceSoftwareDecode: true))
        let host = UIWindow(frame: UIScreen.main.bounds)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { host.windowScene = scene }
        host.rootViewController = quick
        host.makeKeyAndVisible()
        window = host
        player = quick.player
        try await wait("两路自动选轨") { MPVSubtitleSlot.allCases.allSatisfy { quick.player.subtitleState(in: $0).trackID != nil } }
        quick.player.pause()
        XCTAssertTrue(quick.player.seek(to: 2))
        let (first, second) = try labels(quick.player)
        try await wait("自动字幕实际绘制") { first.text == "PRIMARY_ALPHA" && second.text == "ASS_ONE" }
        quick.showSubtitleControl(in: .secondary)
        let panel = try XCTUnwrap(quick.settingsPanelOverlay as? MPVQuickPlayerSubtitleControlView)
        let layout = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "MPVQuickPlayer.subtitleLayoutMode" } as? UISegmentedControl)
        let position = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "MPVQuickPlayer.subtitlePosition" } as? UISlider)
        layout.selectedSegmentIndex = 1
        layout.sendActions(for: .valueChanged)
        XCTAssertEqual(MPVQuickPlayerSubtitlePreferences.layoutMode, .stacked)
        XCTAssertFalse(position.isEnabled)
        try assertStacked(quick.player)
        for slot in MPVSubtitleSlot.allCases {
            XCTAssertEqual(UserDefaults.standard.dictionary(forKey: "MPVQuickPlayer.subtitle.\(slot.rawValue)") as NSDictionary?, before[slot.rawValue])
        }
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.bounds).image { _ in
            host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
        })
        attachment.name = "QuickPlayer-第二字幕显示方式-跟随"
        attachment.lifetime = .keepAlways
        add(attachment)
        panel.onOriginalStyle?(true)
        let note = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "MPVQuickPlayer.subtitleLayoutNote" } as? UILabel)
        try await wait("原始 ASS 自动临时回退并提示") {
            quick.player.subtitleLayoutStatus.fallbackReason == .originalStyle &&
                note.text?.contains(mpvLocalized("subtitle.layout.fallback.originalStyle")) == true
        }
        XCTAssertEqual(MPVQuickPlayerSubtitlePreferences.layoutMode, .stacked)
        panel.onOriginalStyle?(false)
        try await wait("播放器样式自动恢复跟随") { quick.player.subtitleLayoutStatus.effectiveMode == .stacked }
        XCTAssertTrue(MPVQuickPlayerSubtitlePreferences.control(in: .primary).usesOriginalStyle)
        XCTAssertFalse(MPVQuickPlayerSubtitlePreferences.control(in: .secondary).usesOriginalStyle)
        XCTAssertEqual(MPVQuickPlayerSubtitlePreferences.control(in: .secondary).position, 15)
        let reopened = MPVQuickPlayerViewController(configuration: .init(url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        XCTAssertEqual(reopened.player.subtitleLayoutMode, .stacked)
        reopened.player.stop()
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private final class CustomRenderer: MPVSubtitleRenderer {
        let view = UIView()
        func render(_ presentation: MPVSubtitlePresentation) {}
        func clear() {}
    }
}
