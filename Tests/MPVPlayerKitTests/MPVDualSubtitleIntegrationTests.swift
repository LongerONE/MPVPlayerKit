import XCTest
import UIKit
@testable import MPVPlayerKit

/// Demo XCTest host 专用：实际使用原版 libmpv，不以 mock 或旧 P0 补丁验收。
/// 所有等待最多 8 秒；本地 12 秒视频不会无限播放。
final class MPVDualSubtitleIntegrationTests: XCTestCase {
    @MainActor private var player: MPVPlayer?
    @MainActor private var window: UIWindow?

    @MainActor private func fixture(_ name: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil,
                                       subdirectory: "SubtitleFixtures") else {
            XCTFail("缺少 Demo XCTest host 中的 SubtitleFixtures：\(name)")
            throw WaitFailure.timeout
        }
        return url
    }

    @MainActor private func start() async throws -> MPVPlayer {
        let configuration = MPVPlayerConfiguration(url: try fixture("dual-subtitles.mp4"),
                                                  forceSoftwareDecode: true)
        let value = MPVPlayer(configuration: configuration)
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        value.playbackView.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        controller.view.addSubview(value.playbackView)
        let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            host.windowScene = scene
        }
        host.rootViewController = controller
        host.makeKeyAndVisible()
        window = host
        player = value
        value.play()
        try await eventually("视频已打开") { value.duration > 0 && value.currentTime > 0 }
        value.pause()
        return value
    }

    @MainActor private func cleanUp() {
        player?.stop()
        player = nil
        window?.isHidden = true
        window = nil
    }

    @MainActor private func eventually(
        _ reason: String, timeout: TimeInterval = 8,
        _ predicate: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("等待超时：\(reason)")
        throw WaitFailure.timeout
    }

    private enum WaitFailure: Error { case timeout }

    @MainActor func testDeferredASSImportKeepsOriginalSlotAndPreference() async throws {
        let saved = MPVSubtitleSlot.allCases.map { UserDefaults.standard.object(forKey: "MPVQuickPlayer.subtitle.\($0.rawValue)") }
        defer {
            cleanUp()
            for slot in MPVSubtitleSlot.allCases { UserDefaults.standard.set(saved[slot.rawValue], forKey: "MPVQuickPlayer.subtitle.\(slot.rawValue)") }
        }
        for slot in MPVSubtitleSlot.allCases {
            MPVQuickPlayerSubtitlePreferences.save(.init(position: 50, usesOriginalStyle: false), in: slot)
        }
        let quick = MPVQuickPlayerViewController(configuration: MPVPlayerConfiguration(
            url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        let host = UIWindow(frame: UIScreen.main.bounds)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { host.windowScene = scene }
        host.rootViewController = quick
        host.makeKeyAndVisible()
        window = host
        player = quick.player
        try await eventually("QuickPlayer 已启动") { quick.player.duration > 0 }
        quick.player.pause()
        quick.subtitleImportSlot = .primary
        quick.documentPicker(UIDocumentPickerViewController(forOpeningContentTypes: [.data]),
                             didPickDocumentsAt: [try fixture("original.ass")])
        let menu = try XCTUnwrap(quick.actionSheetOverlay)
        let table = try XCTUnwrap(descendants(menu).first { $0 is UITableView } as? UITableView)
        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        quick.subtitleImportSlot = .secondary
        try await eventually("延迟菜单操作完成") {
            MPVSubtitleSlot.allCases.contains { quick.player.subtitleState(in: $0).supportsASSMode }
        }
        XCTAssertTrue(quick.player.subtitleState(in: .primary).supportsASSMode)
        XCTAssertNil(quick.player.subtitleState(in: .secondary).trackID)
        XCTAssertTrue(MPVQuickPlayerSubtitlePreferences.control(in: .primary).usesOriginalStyle)
        XCTAssertFalse(MPVQuickPlayerSubtitlePreferences.control(in: .secondary).usesOriginalStyle)
    }

    @MainActor func testRebuildKeepsLatestASSChoiceWhileRestorationWaits() async throws {
        defer { cleanUp() }
        let value = try await start()
        try await load("original.ass", in: .primary, on: value, original: true)
        try await load("original.ssa", in: .secondary, on: value, original: false)
        let snapshot = value.subtitleSessionSnapshot()
        value.stop()
        value.playbackView.removeFromSuperview()
        let rebuilt = MPVPlayer(configuration: MPVPlayerConfiguration(
            url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        player = rebuilt
        rebuilt.playbackView.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        window?.rootViewController?.view.addSubview(rebuilt.playbackView)
        rebuilt.restoreSubtitleSession(snapshot)
        rebuilt.setSubtitleUsesOriginalStyle(false, in: .primary)
        rebuilt.setSubtitleUsesOriginalStyle(true, in: .secondary)
        rebuilt.play()
        try await eventually("重建恢复两路 ASS") {
            rebuilt.subtitleState(in: .primary).supportsASSMode && rebuilt.subtitleState(in: .secondary).supportsASSMode
        }
        XCTAssertFalse(rebuilt.subtitleState(in: .primary).usesOriginalStyle)
        XCTAssertTrue(rebuilt.subtitleState(in: .secondary).usesOriginalStyle)
    }

    @MainActor func testQuickPlayerASSPreferencesSurvivePlainTextAndExplicitChoices() async throws {
        let saved = MPVSubtitleSlot.allCases.map { UserDefaults.standard.object(forKey: "MPVQuickPlayer.subtitle.\($0.rawValue)") }
        defer {
            cleanUp()
            for slot in MPVSubtitleSlot.allCases { UserDefaults.standard.set(saved[slot.rawValue], forKey: "MPVQuickPlayer.subtitle.\(slot.rawValue)") }
        }
        for slot in MPVSubtitleSlot.allCases {
            MPVQuickPlayerSubtitlePreferences.save(.init(position: slot == .primary ? 100 : 0, usesOriginalStyle: true), in: slot)
        }
        let quick = MPVQuickPlayerViewController(configuration: MPVPlayerConfiguration(
            url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        let host = UIWindow(frame: UIScreen.main.bounds)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { host.windowScene = scene }
        host.rootViewController = quick
        host.makeKeyAndVisible()
        window = host
        player = quick.player
        try await eventually("QuickPlayer 已启动") { quick.player.duration > 0 }
        quick.player.pause()
        for slot in MPVSubtitleSlot.allCases {
            for name in ["original.ass", "primary.srt", "original.ssa", "secondary.vtt", "original.ass"] {
                quick.loadExternalSubtitle(from: try fixture(name), in: slot, usesOriginalStyle: false)
                try await eventually("QuickPlayer 加载 \(name)") { quick.subtitleRequests[slot] == nil }
                let isASS = name.hasSuffix(".ass") || name.hasSuffix(".ssa")
                let state = quick.player.subtitleState(in: slot)
                XCTAssertNotNil(state.trackID)
                XCTAssertEqual(state.supportsASSMode, isASS)
                XCTAssertEqual(state.usesOriginalStyle, isASS)
                XCTAssertEqual(state.assOverride, isASS ? .no : .strip)
                XCTAssertTrue(MPVQuickPlayerSubtitlePreferences.control(in: slot).usesOriginalStyle)
                quick.showSubtitleControl(in: slot)
                let panel = try XCTUnwrap(quick.settingsPanelOverlay as? MPVQuickPlayerSubtitleControlView)
                let toggle = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "MPVQuickPlayer.subtitleASSMode" } as? UISwitch)
                XCTAssertEqual(toggle.superview?.isHidden, !isASS)
                XCTAssertTrue(toggle.isOn)
                if !isASS {
                    panel.onReset?()
                    XCTAssertTrue(MPVQuickPlayerSubtitlePreferences.control(in: slot).usesOriginalStyle)
                }
                attach("\(slot.rawValue)-\(name)-ASS模式入口")
                panel.dismiss(animated: false)
            }
            XCTAssertTrue(quick.player.clearSubtitle(in: slot))
        }
        quick.loadExternalSubtitle(from: try fixture("original.ass"), in: .primary, usesOriginalStyle: false, saveASSPreference: true)
        try await eventually("用户明确选择播放器样式") { quick.subtitleRequests[.primary] == nil }
        XCTAssertFalse(MPVQuickPlayerSubtitlePreferences.control(in: .primary).usesOriginalStyle)
        XCTAssertTrue(MPVQuickPlayerSubtitlePreferences.control(in: .secondary).usesOriginalStyle)
        XCTAssertFalse(quick.player.subtitleState(in: .primary).usesOriginalStyle)
    }

    @MainActor func testEmbeddedModesAutomaticSelectionAndRebuildUseActualFormat() async throws {
        let saved = MPVSubtitleSlot.allCases.map { UserDefaults.standard.object(forKey: "MPVQuickPlayer.subtitle.\($0.rawValue)") }
        defer {
            cleanUp()
            for slot in MPVSubtitleSlot.allCases { UserDefaults.standard.set(saved[slot.rawValue], forKey: "MPVQuickPlayer.subtitle.\(slot.rawValue)") }
        }
        let value = try await start()
        value.playbackView.configure(["url": try fixture("style-modes.mkv").absoluteString, "forceSoftwareDecode": true])
        value.play()
        try await eventually("内嵌轨道加载") { value.tracks(ofType: .subtitle).count == 2 }
        value.pause()
        let tracks = value.tracks(ofType: .subtitle)
        let ass = try XCTUnwrap(tracks.first { MPVPlayerView.isASSSubtitleCodec($0.codec) })
        let srt = try XCTUnwrap(tracks.first { $0.codec == "subrip" })
        for slot in MPVSubtitleSlot.allCases {
            for track in [ass, srt, ass] {
                XCTAssertTrue(value.select(track: track, in: slot, usesOriginalStyle: true))
                let state = value.subtitleState(in: slot)
                XCTAssertEqual(state.supportsASSMode, track.id == ass.id)
                XCTAssertEqual(state.usesOriginalStyle, track.id == ass.id)
                value.setSubtitleDelay(1.25, in: slot)
                value.setSubtitlePosition(55, in: slot)
            }
            XCTAssertTrue(value.clearSubtitle(in: slot))
        }
        XCTAssertTrue(value.select(track: srt, in: .primary, usesOriginalStyle: true))
        XCTAssertTrue(value.select(track: ass, in: .secondary, usesOriginalStyle: true))
        let snapshot = value.subtitleSessionSnapshot()
        value.stop()
        value.playbackView.removeFromSuperview()
        let rebuilt = MPVPlayer(configuration: MPVPlayerConfiguration(url: try fixture("style-modes.mkv"), forceSoftwareDecode: true))
        player = rebuilt
        rebuilt.playbackView.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        window?.rootViewController?.view.addSubview(rebuilt.playbackView)
        rebuilt.restoreSubtitleSession(snapshot)
        rebuilt.play()
        try await eventually("重建按格式恢复") {
            rebuilt.subtitleState(in: .primary).trackID != nil && rebuilt.subtitleState(in: .secondary).supportsASSMode
        }
        XCTAssertFalse(rebuilt.subtitleState(in: .primary).usesOriginalStyle)
        XCTAssertEqual(rebuilt.subtitleState(in: .primary).shadowRadiusCapability, .supported)
        XCTAssertTrue(rebuilt.subtitleState(in: .secondary).usesOriginalStyle)
        rebuilt.stop()
        MPVQuickPlayerSubtitlePreferences.save(.init(position: 100, usesOriginalStyle: true, automatic: true, language: .english), in: .primary)
        MPVQuickPlayerSubtitlePreferences.save(.init(position: 0, usesOriginalStyle: false, automatic: true, language: .simplifiedChinese), in: .secondary)
        let quick = MPVQuickPlayerViewController(configuration: MPVPlayerConfiguration(url: try fixture("style-modes.mkv"), forceSoftwareDecode: true))
        window?.rootViewController = quick
        player = quick.player
        try await eventually("两路自动选轨") {
            quick.player.subtitleState(in: .primary).trackID != nil && quick.player.subtitleState(in: .secondary).trackID != nil
        }
        XCTAssertFalse(quick.player.subtitleState(in: .primary).usesOriginalStyle)
        XCTAssertFalse(quick.player.subtitleState(in: .primary).supportsASSMode)
        XCTAssertTrue(quick.player.subtitleState(in: .secondary).supportsASSMode)
        XCTAssertFalse(quick.player.subtitleState(in: .secondary).usesOriginalStyle)
        quick.player.pause()
        try await seek(2, on: quick.player)
        let automaticLabel = try XCTUnwrap(quick.player.playbackView.secondarySubtitleRenderer.view.subviews.first as? UILabel)
        try await eventually("自动选择 ASS 的实际自绘台词") { automaticLabel.attributedText?.string.contains("ASS_ONE") == true }
        XCTAssertEqual(quick.player.subtitleState(in: .secondary).shadowRadiusCapability, .supported)
        XCTAssertTrue(MPVQuickPlayerSubtitlePreferences.control(in: .primary).usesOriginalStyle)
        XCTAssertFalse(MPVQuickPlayerSubtitlePreferences.control(in: .secondary).usesOriginalStyle)
    }

    @MainActor func testQuickPlayerShadowRadiusFollowsActualRoutesWhilePaused() async throws {
        let saved = MPVQuickPlayerSubtitlePreferences.style()
        defer { cleanUp(); MPVQuickPlayerSubtitlePreferences.save(saved) }
        let quick = MPVQuickPlayerViewController(configuration: MPVPlayerConfiguration(
            url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        quick.subtitleControls[.primary]?.position = 100
        quick.subtitleControls[.secondary]?.position = 0
        quick.applySubtitlePreferences()
        let host = UIWindow(frame: UIScreen.main.bounds)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { host.windowScene = scene }
        host.rootViewController = quick
        host.makeKeyAndVisible()
        window = host
        let value = quick.player
        player = value
        try await eventually("QuickPlayer 加载视频") { value.duration > 0 }
        value.pause()
        quick.showSharedSubtitleStyle()
        let panel = try XCTUnwrap(quick.settingsPanelOverlay as? MPVQuickPlayerSubtitleSettingsView)
        let slider = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "MPVQuickPlayer.subtitleShadowRadius" } as? UISlider)
        let note = try XCTUnwrap(descendants(panel).first { $0.accessibilityIdentifier == "MPVQuickPlayer.subtitleShadowRadiusNote" } as? UILabel)
        XCTAssertFalse(slider.isEnabled)
        XCTAssertFalse(note.isHidden)
        try await load("primary.srt", in: .primary, on: value)
        try await eventually("仅自绘时允许设置") { slider.isEnabled && note.isHidden }
        XCTAssertEqual(value.subtitleState(in: .primary).shadowRadiusCapability, .supported)
        try await load("secondary.vtt", in: .secondary, on: value)
        try await eventually("两路自绘允许设置") { slider.isEnabled && note.isHidden }
        XCTAssertEqual(value.subtitleState(in: .secondary).shadowRadiusCapability, .supported)
        try await seek(2, on: value)
        try await eventually("第一路自绘文本") { value.currentSubtitleText(in: .primary)?.contains("PRIMARY_ALPHA") == true }
        var style = saved
        style.shadowOffset = 4
        style.shadowRadius = 0
        quick.setSubtitleStyle(style)
        panel.update(style: style, delay: 0)
        let label = try XCTUnwrap(value.playbackView.clientSubtitleRenderer.view.subviews.first as? UILabel)
        let secondaryLabel = try XCTUnwrap(value.playbackView.secondarySubtitleRenderer.view.subviews.first as? UILabel)
        try await eventually("第二路实际自绘文本") { secondaryLabel.attributedText?.string.contains("SECONDARY_ONE") == true }
        let text = label.attributedText?.string
        attach("半径-0-两路自绘")
        panel.isHidden = true
        attach("两路字幕呈现-半径0")
        panel.isHidden = false
        slider.value = 14
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(label.layer.shadowRadius, 14)
        XCTAssertEqual(label.attributedText?.string, text)
        XCTAssertEqual(MPVQuickPlayerSubtitlePreferences.style().shadowRadius, 14)
        XCTAssertFalse(value.subtitleState(in: .secondary).nativeVisible)
        XCTAssertEqual(secondaryLabel.layer.shadowRadius, 14)
        attach("半径-14-两路同时生效")
        panel.isHidden = true
        attach("两路字幕呈现-半径14")
        panel.isHidden = false
        value.setSubtitleUsesOriginalStyle(true, in: .primary)
        try await eventually("SRT 不受 ASS 偏好影响") { slider.isEnabled && !value.subtitleState(in: .primary).usesOriginalStyle }
        XCTAssertEqual(MPVQuickPlayerSubtitlePreferences.style().shadowRadius, 14)
        XCTAssertEqual(label.layer.shadowRadius, 14)
        try await load("original.ass", in: .primary, on: value, original: true)
        try await eventually("原始 ASS 与第二路自绘混合提示") { slider.isEnabled && !note.isHidden && value.subtitleState(in: .primary).shadowRadiusCapability == .originalStyle }
        try await load("original.ssa", in: .secondary, on: value, original: true)
        try await eventually("两路原始样式禁用半径") { !slider.isEnabled }
        attach("原生字幕-禁用并解释")
        value.setSubtitleUsesOriginalStyle(false, in: .primary)
        try await eventually("ASS 播放器样式支持半径") { slider.isEnabled && value.subtitleState(in: .primary).shadowRadiusCapability == .supported }
        try await load("primary.srt", in: .primary, on: value)
        try await eventually("切回 SRT 恢复半径") { slider.isEnabled }
        XCTAssertEqual(label.layer.shadowRadius, 14)
        value.setSubtitlesVisible(false, in: .secondary)
        try await eventually("隐藏的第二路不参与限制") { note.isHidden }
        value.setSubtitlesVisible(false, in: .primary)
        try await eventually("全部隐藏后没有可用字幕") { !slider.isEnabled && !note.isHidden }
        XCTAssertEqual(MPVQuickPlayerSubtitlePreferences.style().shadowRadius, 14)
    }

    @MainActor private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor private func load(
        _ name: String, in slot: MPVSubtitleSlot, on player: MPVPlayer,
        succeeds: Bool = true, original: Bool = false
    ) async throws {
        var result: Bool?
        var completions = 0
        player.loadExternalSubtitle(from: try fixture(name), in: slot,
                                    usesOriginalStyle: original) {
            result = $0
            completions += 1
        }
        try await eventually("外挂 \(name) 完成") { result != nil }
        XCTAssertEqual(result, succeeds)
        XCTAssertEqual(completions, 1)
    }

    @MainActor private func seek(_ time: Double, on player: MPVPlayer) async throws {
        XCTAssertTrue(player.seek(to: time))
        try await eventually("精确定位 \(time)") { abs(player.currentTime - time) < 0.25 }
    }

    @MainActor private func attach(_ name: String) {
        guard let view = window else { return }
        view.layoutIfNeeded()
        if let note = descendants(view).first(where: {
            $0.accessibilityIdentifier == "MPVQuickPlayer.subtitleShadowRadiusNote" && !$0.isHidden
        }) {
            for scroll in descendants(view).compactMap({ $0 as? UIScrollView }) where note.isDescendant(of: scroll) {
                scroll.scrollRectToVisible(note.convert(note.bounds, to: scroll).insetBy(dx: 0, dy: -12), animated: false)
            }
        }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testTwoDecodedTracksTextAndDuplicateRejection() async throws {
        defer { cleanUp() }
        let player = try await start()
        try await load("primary.srt", in: .primary, on: player)
        try await load("secondary.vtt", in: .secondary, on: player)
        try await seek(2, on: player)
        try await eventually("两路字幕正文") {
            player.currentSubtitleText(in: .primary)?.contains("PRIMARY_ALPHA") == true &&
            player.currentSubtitleText(in: .secondary)?.contains("SECONDARY_ONE") == true
        }
        let primary = player.subtitleState(in: .primary)
        let secondary = player.subtitleState(in: .secondary)
        XCTAssertNotNil(primary.trackID)
        XCTAssertNotNil(secondary.trackID)
        XCTAssertNotEqual(primary.trackID, secondary.trackID)
        XCTAssertFalse(secondary.nativeVisible)
        XCTAssertFalse(secondary.isNative)
        let occupied = try XCTUnwrap(player.tracks(ofType: .subtitle).first {
            Int64($0.id) == primary.trackID
        })
        XCTAssertFalse(player.select(track: occupied, in: .secondary))
        XCTAssertEqual(player.subtitleState(in: .secondary).trackID, secondary.trackID)
        attach("V01-双字幕-正文回读另有断言")
    }

    @MainActor func testIndependentDelayVisibilityPositionAndASS() async throws {
        defer { cleanUp() }
        let player = try await start()
        try await load("primary.srt", in: .primary, on: player)
        try await load("secondary.vtt", in: .secondary, on: player)
        player.setSubtitleDelay(2, in: .secondary)
        player.setSubtitlePosition(35, in: .secondary)
        player.setSubtitlesVisible(false, in: .secondary)
        try await eventually("第二路控制回读") {
            let state = player.subtitleState(in: .secondary)
            return state.delay == 2 && state.position == 35 && !state.visible
        }
        XCTAssertEqual(player.subtitleState(in: .primary).delay, 0)
        XCTAssertTrue(player.subtitleState(in: .primary).visible)
        player.setSubtitlesVisible(true, in: .secondary)
        try await seek(5, on: player)
        try await eventually("第二路延迟两秒，第一路时间不变") {
            player.currentSubtitleText(in: .primary)?.contains("PRIMARY_BRAVO") == true &&
            player.currentSubtitleText(in: .secondary)?.contains("SECONDARY_ONE") == true
        }
        let secondaryLabel = try XCTUnwrap(player.playbackView.secondarySubtitleRenderer.view.subviews.first as? UILabel)
        try await eventually("第二路自绘按独立延迟显示旧句") { secondaryLabel.attributedText?.string.contains("SECONDARY_ONE") == true }
        player.setSubtitleDelay(-1, in: .secondary)
        try await seek(3.5, on: player)
        try await eventually("第二路负延迟显示下一句") { secondaryLabel.attributedText?.string.contains("SECONDARY_TWO") == true }
        try await load("original.ass", in: .secondary, on: player, original: true)
        try await eventually("原始 ASS 清空自绘层") { secondaryLabel.attributedText == nil }
        XCTAssertTrue(player.subtitleState(in: .secondary).usesOriginalStyle)
        player.setSubtitleUsesOriginalStyle(false, in: .secondary)
        try await eventually("退出原始 ASS 模式") {
            !player.subtitleState(in: .secondary).usesOriginalStyle &&
                player.subtitleState(in: .secondary).shadowRadiusCapability == .supported
        }
        XCTAssertFalse(player.subtitleState(in: .secondary).nativeVisible)
        try await seek(2, on: player)
        try await eventually("ASS 播放器样式实际自绘") { secondaryLabel.attributedText?.string.contains("ASS_ONE") == true }
        attach("V02-第二路位置35")
    }

    @MainActor func testClientPrimaryClearDoesNotClearSecondary() async throws {
        defer { cleanUp() }
        let player = try await start()
        try await load("secondary.vtt", in: .secondary, on: player)
        let subtitleURL = try fixture("primary.srt")
        let document = try MPVSubtitleDocument.decode(
            Data(contentsOf: subtitleURL), sourceURL: subtitleURL)
        player.selectClientSubtitle(document)
        try await seek(2, on: player)
        try await eventually("自绘共存") {
            player.currentSubtitleText(in: .secondary)?.contains("SECONDARY_ONE") == true
        }
        let secondaryID = player.subtitleState(in: .secondary).trackID
        player.setSubtitlesVisible(false)
        XCTAssertTrue(player.subtitleState(in: .secondary).visible)
        player.clearClientSubtitle()
        XCTAssertEqual(player.subtitleState(in: .secondary).trackID, secondaryID)
        XCTAssertFalse(player.subtitleState(in: .secondary).nativeVisible)
        attach("V04-第一路清理后第二路保留")
    }

    @MainActor func testDocumentAndSecondaryRestoreAcrossPlayerRebuild() async throws {
        defer { cleanUp() }
        let original = try await start()
        try await load("secondary.vtt", in: .secondary, on: original)
        let url = try fixture("primary.srt")
        original.selectClientSubtitle(try MPVSubtitleDocument.decode(Data(contentsOf: url), sourceURL: url))
        original.setSubtitleDelay(1.25, in: .primary)
        original.setSubtitleDelay(1.5, in: .secondary)
        original.setSubtitlesVisible(false, in: .secondary)
        try await eventually("重建前第二路隐藏与校时") {
            let state = original.subtitleState(in: .secondary)
            return !state.visible && state.delay == 1.5
        }
        let snapshot = original.subtitleSessionSnapshot()
        original.stop()
        original.playbackView.removeFromSuperview()
        let rebuilt = MPVPlayer(configuration: MPVPlayerConfiguration(
            url: try fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
        player = rebuilt
        rebuilt.playbackView.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        window?.rootViewController?.view.addSubview(rebuilt.playbackView)
        rebuilt.restoreSubtitleSession(snapshot)
        rebuilt.play()
        try await eventually("新句柄恢复文档与第二路") {
            let secondary = rebuilt.subtitleState(in: .secondary)
            return secondary.trackID != nil && !secondary.visible && secondary.delay == 1.5 &&
                !rebuilt.subtitleState(in: .primary).isNative &&
                rebuilt.subtitleState(in: .primary).delay == 1.25
        }
        XCTAssertNil(rebuilt.subtitleState(in: .primary).trackID)
        try await seek(2, on: rebuilt)
        rebuilt.pause()
        XCTAssertFalse(rebuilt.subtitleState(in: .secondary).nativeVisible)
        let label = try XCTUnwrap(rebuilt.playbackView.secondarySubtitleRenderer.view.subviews.first as? UILabel)
        XCTAssertNil(label.attributedText)
        rebuilt.setSubtitlesVisible(true, in: .secondary)
        try await seek(5, on: rebuilt)
        try await eventually("重建后自绘继续按第二路延迟显示") { label.attributedText?.string.contains("SECONDARY_ONE") == true }
        XCTAssertEqual(rebuilt.subtitleState(in: .secondary).shadowRadiusCapability, .supported)
        attach("V11-文档与第二路重建恢复")
    }

    @MainActor func testSourceDelayRestoresOnlyForPreviouslyAdjustedSource() async throws {
        defer { cleanUp() }
        let player = try await start()
        try await load("secondary.vtt", in: .secondary, on: player)
        player.setSubtitleDelay(2.5, in: .secondary)
        try await eventually("来源A校时") { player.subtitleState(in: .secondary).delay == 2.5 }
        try await load("original.ass", in: .secondary, on: player)
        XCTAssertEqual(player.subtitleState(in: .secondary).delay, 0)
        player.setSubtitleDelay(-1, in: .secondary)
        try await load("secondary.vtt", in: .secondary, on: player)
        XCTAssertEqual(player.subtitleState(in: .secondary).delay, 2.5)
    }

    @MainActor func testNewMediaClearsSelectionsAndSessionDelay() async throws {
        defer { cleanUp() }
        let player = try await start()
        try await load("secondary.vtt", in: .secondary, on: player)
        player.setSubtitleDelay(3, in: .secondary)
        let source = try fixture("dual-subtitles.mp4")
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("dual-subtitle-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: source, to: replacement)
        defer { try? FileManager.default.removeItem(at: replacement) }
        player.playbackView.configure(["url": replacement.absoluteString])
        player.play()
        try await eventually("换片后清空第二路来源与延迟") {
            let state = player.subtitleState(in: .secondary)
            return state.trackID == nil && state.sourceID == nil && state.delay == 0
        }
        XCTAssertNil(player.subtitleState(in: .primary).trackID)
    }

    @MainActor func testFailedLoadAndCancellationPreserveOtherSlot() async throws {
        defer { cleanUp() }
        let player = try await start()
        try await load("primary.srt", in: .primary, on: player)
        try await load("secondary.vtt", in: .secondary, on: player)
        try await seek(2, on: player)
        try await eventually("失败前第二路正文") {
            player.currentSubtitleText(in: .secondary)?.contains("SECONDARY_ONE") == true
        }
        let before = player.subtitleState(in: .secondary)
        try await load("empty.srt", in: .secondary, on: player, succeeds: false)
        XCTAssertEqual(player.subtitleState(in: .secondary).trackID, before.trackID)
        var result: Bool?
        var completions = 0
        let missing = try fixture("dual-subtitles.mp4").deletingLastPathComponent()
            .appendingPathComponent("does-not-exist.srt")
        player.loadExternalSubtitle(from: missing, in: .secondary) {
            result = $0
            completions += 1
        }
        try await eventually("不存在文件失败") { result != nil }
        XCTAssertEqual(result, false)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(player.subtitleState(in: .secondary).trackID, before.trackID)
        var cancelled: Bool?
        var cancelledCount = 0
        let request = player.loadExternalSubtitle(from: try fixture("original.ass"), in: .secondary) {
            cancelled = $0
            cancelledCount += 1
        }
        player.cancelExternalSubtitleLoad(request)
        try await eventually("取消请求完成") { cancelled != nil }
        XCTAssertEqual(cancelled, false)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(player.subtitleState(in: .secondary).trackID, before.trackID)
        XCTAssertFalse(player.subtitleState(in: .secondary).nativeVisible)
        XCTAssertTrue(player.currentSubtitleText(in: .secondary)?.contains("SECONDARY_ONE") == true)
        XCTAssertNotNil(player.subtitleState(in: .primary).trackID)
    }
}
