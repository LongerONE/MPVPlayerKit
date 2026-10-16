import XCTest

/// 真实模拟器窗口截图，包含 Metal 视频层；通过 UI 操作检查新面板入口。
final class MPVPlayerKitDemoUITests: XCTestCase {
    @MainActor func testDualSubtitlePanelsAndSharedStyle() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--dual-subtitle-demo", "-AppleLanguages", "(zh-Hans)",
                               "-AppleLocale", "zh_CN"]
        app.launch()
        let subtitleButton = app.buttons["MPVQuickPlayer.subtitleButton"]
        XCTAssertTrue(subtitleButton.waitForExistence(timeout: 12))
        // 诊断入口等待加载两路后暂停在2秒。等待可见标签保证不是空播放器截图。
        let ready = app.staticTexts["双字幕诊断已就绪"]
        XCTAssertTrue(ready.waitForExistence(timeout: 12))
        capture("V01-原版双字幕实际窗口")
        for name in ["第一字幕", "第二字幕"] {
            if !subtitleButton.isHittable { app.tap() }
            subtitleButton.tap()
            let item = app.buttons[name]
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.tap()
            let panel = app.otherElements["MPVQuickPlayer.subtitleControl"]
            XCTAssertTrue(panel.waitForExistence(timeout: 3))
            capture("QuickPlayer-\(name)控制")
            let cancel = app.buttons["取消"].firstMatch
            XCTAssertTrue(cancel.exists)
            cancel.tap()
        }
        if !subtitleButton.isHittable { app.tap() }
        subtitleButton.tap()
        app.buttons["字幕公共样式"].tap()
        XCTAssertTrue(app.otherElements["MPVQuickPlayer.subtitleSettings"].waitForExistence(timeout: 3))
        capture("QuickPlayer-字幕公共样式")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let details = app.buttons["MPVQuickPlayer.subtitleSettingsDetails"]
        XCTAssertTrue(details.isHittable)
        XCTAssertEqual(details.label, "详情")
        details.tap()
        let alert = app.alerts["字幕公共样式"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        capture("QuickPlayer-字幕公共样式详情")
        alert.buttons.firstMatch.tap()
        XCTAssertTrue(details.waitForExistence(timeout: 3))
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
