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
            let item = app.cells.containing(.staticText, identifier: name).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.tap()
            let panel = app.otherElements["MPVQuickPlayer.subtitleControl"]
            XCTAssertTrue(panel.waitForExistence(timeout: 3))
            let delay = app.steppers["MPVQuickPlayer.subtitleDelay"]
            XCTAssertTrue(delay.exists)
            let initialDelay = delay.value as? String
            delay.buttons["MPVQuickPlayer.subtitleDelay-Increment"].tap()
            XCTAssertNotEqual(delay.value as? String, initialDelay)
            delay.buttons["MPVQuickPlayer.subtitleDelay-Decrement"].tap()
            XCTAssertEqual(delay.value as? String, initialDelay)
            let position = app.sliders["MPVQuickPlayer.subtitlePosition"]
            XCTAssertTrue(position.isEnabled)
            let initialPosition = position.value as? String
            let targetPosition: CGFloat = (Double(initialPosition ?? "0") ?? 0) < 75 ? 0.8 : 0.2
            position.adjust(toNormalizedSliderPosition: targetPosition)
            XCTAssertNotEqual(position.value as? String, initialPosition)
            XCTAssertTrue(panel.exists)
            capture("QuickPlayer-\(name)控制")
            XCTAssertFalse(app.staticTexts["显示字幕"].exists)
            XCTAssertFalse(app.staticTexts["隐藏字幕"].exists)
            app.buttons["MPVQuickPlayer.subtitleSource"].tap()
            XCTAssertFalse(app.staticTexts["取消加载字幕"].exists)
            let off = app.cells.containing(.staticText, identifier: "关闭").firstMatch
            XCTAssertTrue(off.waitForExistence(timeout: 3))
            off.tap()
            XCTAssertTrue(panel.waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["MPVQuickPlayer.subtitleSource"].value as? String, "关闭")
            let cancel = app.buttons["取消"].firstMatch
            XCTAssertTrue(cancel.exists)
            cancel.tap()
        }
        if !subtitleButton.isHittable { app.tap() }
        subtitleButton.tap()
        app.cells.containing(.staticText, identifier: "字幕公共样式").firstMatch.tap()
        XCTAssertTrue(app.otherElements["MPVQuickPlayer.subtitleSettings"].waitForExistence(timeout: 3))
        let radius = app.sliders["MPVQuickPlayer.subtitleShadowRadius"]
        XCTAssertTrue(radius.isEnabled, "关闭字幕后仍应允许预设第一字幕自绘半径")
        let initialRadius = radius.value as? String
        radius.adjust(toNormalizedSliderPosition: initialRadius == "16.0 pt" ? 0.2 : 0.8)
        let changedRadius = radius.value as? String
        XCTAssertNotEqual(changedRadius, initialRadius)
        app.buttons["取消"].firstMatch.tap()
        if !subtitleButton.isHittable { app.tap() }
        subtitleButton.tap()
        app.cells.containing(.staticText, identifier: "字幕公共样式").firstMatch.tap()
        XCTAssertTrue(radius.waitForExistence(timeout: 3))
        XCTAssertEqual(radius.value as? String, changedRadius)
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
