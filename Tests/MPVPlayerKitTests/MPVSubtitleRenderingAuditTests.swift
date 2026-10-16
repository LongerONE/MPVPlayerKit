import XCTest
import UIKit
@testable import MPVPlayerKit

/// 固定素材、真实 libmpv；专门覆盖主线程文本回调和异步恢复的交错。
@MainActor
final class MPVSubtitleRenderingAuditTests: XCTestCase {
    private var player: MPVPlayer?
    private var window: UIWindow?

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "SubtitleFixtures"))
    }

    private func start() async throws -> MPVPlayer {
        let value = MPVPlayer(configuration: .init(url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { host.windowScene = scene }
        let controller = UIViewController()
        host.rootViewController = controller
        value.playbackView.frame = host.bounds
        controller.view.addSubview(value.playbackView)
        host.makeKeyAndVisible()
        window = host
        player = value
        value.play()
        try await wait("视频启动") { value.currentTime > 0 }
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
        throw AuditError.timeout
    }

    private enum AuditError: Error { case timeout }

    private func load(_ name: String, in slot: MPVSubtitleSlot, on value: MPVPlayer) async throws {
        var result: Bool?
        value.loadExternalSubtitle(from: try fixture(name), in: slot) { result = $0 }
        try await wait("加载 \(name)") { result != nil }
        XCTAssertEqual(result, true)
    }

    func testQueuedTextCannotRepaintAfterBothSlotsAreCleared() async throws {
        defer { cleanUp() }
        let value = try await start()
        try await load("primary.srt", in: .primary, on: value)
        try await load("secondary.vtt", in: .secondary, on: value)
        XCTAssertTrue(value.seek(to: 2))
        let primary = try XCTUnwrap(value.playbackView.clientSubtitleRenderer.view.subviews.first as? UILabel)
        let secondary = try XCTUnwrap(value.playbackView.secondarySubtitleRenderer.view.subviews.first as? UILabel)
        try await wait("两路实际台词") { primary.attributedText != nil && secondary.attributedText != nil }
        let oldPrimary = primary.attributedText?.string
        let oldSecondary = secondary.attributedText?.string
        // 故意让旧文本在主线程积压；probe 排在旧回调后、清空回调前。
        await withCheckedContinuation { continuation in
            value.playbackView.performOnMPVQueueSync { value.playbackView.refreshSubtitleTextCache() }
            DispatchQueue.main.async {
                XCTAssertNil(primary.attributedText, "旧回调不得让第一路重新出现")
                XCTAssertNil(secondary.attributedText, "旧回调不得让第二路重新出现")
                continuation.resume()
            }
            XCTAssertTrue(value.clearSubtitle(in: .primary))
            XCTAssertTrue(value.clearSubtitle(in: .secondary))
        }
        try await wait("两路最终清空") { primary.attributedText == nil && secondary.attributedText == nil }
        // 将先前真实解码的文本作为晚到发布交给绘制入口；已退役的路必须拒绝绘制。
        value.playbackView.decodedSubtitleText = oldPrimary
        value.playbackView.secondaryDecodedSubtitleText = oldSecondary
        value.playbackView.renderDecodedSubtitleText()
        value.playbackView.renderSecondarySubtitleText()
        XCTAssertNil(primary.attributedText)
        XCTAssertNil(secondary.attributedText)
    }

    func testRebuildKeepsLatestDelayPositionAndVisibility() async throws {
        defer { cleanUp() }
        let value = try await start()
        try await load("primary.srt", in: .primary, on: value)
        try await load("secondary.vtt", in: .secondary, on: value)
        let snapshot = value.subtitleSessionSnapshot()
        value.stop()
        value.playbackView.removeFromSuperview()
        let rebuilt = MPVPlayer(configuration: .init(url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        player = rebuilt
        rebuilt.playbackView.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        window?.rootViewController?.view.addSubview(rebuilt.playbackView)
        rebuilt.restoreSubtitleSession(snapshot)
        rebuilt.setSubtitleDelay(-1, in: .primary)
        rebuilt.setSubtitleDelay(2, in: .secondary)
        rebuilt.setSubtitlePosition(35, in: .secondary)
        rebuilt.setSubtitlesVisible(false, in: .secondary)
        rebuilt.play()
        try await wait("两路恢复") { MPVSubtitleSlot.allCases.allSatisfy { rebuilt.subtitleState(in: $0).trackID != nil } }
        XCTAssertEqual(rebuilt.subtitleState(in: .primary).delay, -1)
        XCTAssertEqual(rebuilt.subtitleState(in: .secondary).delay, 2)
        XCTAssertEqual(rebuilt.subtitleState(in: .secondary).position, 35)
        XCTAssertFalse(rebuilt.subtitleState(in: .secondary).visible)
        let secondary = try XCTUnwrap(rebuilt.playbackView.secondarySubtitleRenderer.view.subviews.first as? UILabel)
        XCTAssertNil(secondary.attributedText)
        rebuilt.pause()
        rebuilt.setSubtitlesVisible(true, in: .secondary)
        XCTAssertTrue(rebuilt.seek(to: 5))
        let primary = try XCTUnwrap(rebuilt.playbackView.clientSubtitleRenderer.view.subviews.first as? UILabel)
        try await wait("恢复后正负延迟实际同步") {
            primary.attributedText?.string.contains("PRIMARY_BRAVO") == true &&
                secondary.attributedText?.string.contains("SECONDARY_ONE") == true
        }
        try await load("original.ass", in: .secondary, on: rebuilt)
        try await load("secondary.vtt", in: .secondary, on: rebuilt)
        XCTAssertEqual(rebuilt.subtitleState(in: .secondary).delay, 2, "恢复后的最新校时须归属正确来源")
    }

    func testImportCompletionCannotOverwriteNewerSavedASSChoice() async throws {
        let saved = MPVSubtitleSlot.allCases.map { UserDefaults.standard.object(forKey: "MPVQuickPlayer.subtitle.\($0.rawValue)") }
        defer {
            cleanUp()
            for slot in MPVSubtitleSlot.allCases { UserDefaults.standard.set(saved[slot.rawValue], forKey: "MPVQuickPlayer.subtitle.\(slot.rawValue)") }
        }
        for slot in MPVSubtitleSlot.allCases {
            MPVQuickPlayerSubtitlePreferences.save(.init(position: slot == .primary ? 100 : 0, usesOriginalStyle: true), in: slot)
        }
        let quick = MPVQuickPlayerViewController(configuration: .init(url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        let host = UIWindow(frame: UIScreen.main.bounds)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { host.windowScene = scene }
        host.rootViewController = quick
        host.makeKeyAndVisible()
        window = host
        player = quick.player
        try await wait("QuickPlayer 启动") { quick.player.duration > 0 }
        quick.player.pause()
        for slot in MPVSubtitleSlot.allCases {
            let name = slot == .primary ? "original.ass" : "original.ssa"
            quick.loadExternalSubtitle(from: try fixture(name), in: slot, usesOriginalStyle: true, saveASSPreference: true)
            quick.updateSubtitleControl(in: slot) { $0.usesOriginalStyle = false }
            quick.player.setSubtitlesVisible(false, in: slot)
            try await wait("导入完成") { quick.subtitleRequests[slot] == nil }
            XCTAssertFalse(MPVQuickPlayerSubtitlePreferences.control(in: slot).usesOriginalStyle)
            XCTAssertFalse(quick.player.subtitleState(in: slot).usesOriginalStyle)
            XCTAssertFalse(quick.player.subtitleState(in: slot).visible)
            quick.loadExternalSubtitle(from: try fixture(name), in: slot, usesOriginalStyle: true, saveASSPreference: true)
            quick.updateSubtitleControl(in: slot, changesASSPreference: true) { $0.usesOriginalStyle = false }
            try await wait("同值明确选择仍优先于导入菜单") { quick.subtitleRequests[slot] == nil }
            XCTAssertFalse(MPVQuickPlayerSubtitlePreferences.control(in: slot).usesOriginalStyle)
        }
    }

    func testPrimaryDelayDoesNotClearDecodedTextAndDocumentSwitchStillAdvances() async throws {
        defer { cleanUp() }
        let value = try await start()
        try await load("primary.srt", in: .primary, on: value)
        try await load("secondary.vtt", in: .secondary, on: value)
        XCTAssertTrue(value.seek(to: 2))
        let primary = try XCTUnwrap(value.playbackView.clientSubtitleRenderer.view.subviews.first as? UILabel)
        let secondary = try XCTUnwrap(value.playbackView.secondarySubtitleRenderer.view.subviews.first as? UILabel)
        try await wait("原生解码两路已有台词") { primary.attributedText != nil && secondary.attributedText != nil }
        value.setSubtitleDelay(0, in: .primary)
        XCTAssertNotNil(primary.attributedText, "仅调整延迟不得先清空解码文本")
        let data = Data("1\n00:00:00,000 --> 00:00:04,000\nDOC_ONE\n\n2\n00:00:04,000 --> 00:00:08,000\nDOC_TWO".utf8)
        value.selectClientSubtitle(try MPVSubtitleDocument.decode(data, sourceURL: URL(fileURLWithPath: "/document.srt")))
        XCTAssertTrue(value.seek(to: 5))
        try await wait("切换文档后第一路继续推进，第二路独立") {
            primary.attributedText?.string.contains("DOC_TWO") == true &&
                secondary.attributedText?.string.contains("SECONDARY_TWO") == true
        }
    }

    func testRapidSwitchesKeepCueTimingAndSavedPreferencesIndependent() async throws {
        let saved = MPVSubtitleSlot.allCases.map { UserDefaults.standard.dictionary(forKey: "MPVQuickPlayer.subtitle.\($0.rawValue)") as NSDictionary? }
        defer { cleanUp() }
        let value = try await start()
        try await load("original.ass", in: .secondary, on: value)
        try await load("primary.srt", in: .primary, on: value)
        try await load("secondary.vtt", in: .secondary, on: value)
        let tracks = value.tracks(ofType: .subtitle)
        let ass = try XCTUnwrap(tracks.first { MPVPlayerView.isASSSubtitleCodec($0.codec) })
        let vtt = try XCTUnwrap(tracks.first { $0.codec == "webvtt" })
        let primary = try XCTUnwrap(value.playbackView.clientSubtitleRenderer.view.subviews.first as? UILabel)
        let secondary = try XCTUnwrap(value.playbackView.secondarySubtitleRenderer.view.subviews.first as? UILabel)
        for index in 0..<12 {
            XCTAssertTrue(value.select(track: ass, in: .secondary, usesOriginalStyle: true))
            value.setSubtitlesVisible(false, in: .secondary)
            XCTAssertTrue(value.select(track: vtt, in: .secondary, usesOriginalStyle: true))
            value.setSubtitleDelay(index.isMultiple(of: 2) ? 2 : -1, in: .secondary)
            value.setSubtitlesVisible(true, in: .secondary)
            XCTAssertTrue(value.seek(to: 5))
            let expected = index.isMultiple(of: 2) ? "SECONDARY_ONE" : "SECONDARY_TWO"
            try await wait("快速切换后两路台词及延迟一致") {
                primary.attributedText?.string.contains("PRIMARY_BRAVO") == true &&
                    secondary.attributedText?.string.contains(expected) == true
            }
            XCTAssertFalse(value.subtitleState(in: .secondary).usesOriginalStyle)
            XCTAssertEqual(value.subtitleState(in: .primary).delay, 0)
        }
        XCTAssertTrue(value.select(track: ass, in: .secondary, usesOriginalStyle: true))
        try await wait("原始 ASS 无自绘残留") { secondary.attributedText == nil }
        XCTAssertTrue(value.clearSubtitle(in: .secondary))
        try await wait("关闭第二路后第一路保留") { secondary.attributedText == nil && primary.attributedText != nil }
        for slot in MPVSubtitleSlot.allCases {
            XCTAssertEqual(UserDefaults.standard.dictionary(forKey: "MPVQuickPlayer.subtitle.\(slot.rawValue)") as NSDictionary?, saved[slot.rawValue])
        }
    }
}
