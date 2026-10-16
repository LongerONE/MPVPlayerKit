import XCTest
import UIKit
@testable import MPVPlayerKit

/// 字幕字重数值化：SRT 等文本字幕走 UIKit 自绘路径，按数值字重取真实字面；
/// ASS 自带样式轨仍降级为 `sub-bold` 布尔。
final class MPVSubtitleFontWeightTests: XCTestCase {

    // MARK: - 模型层

    func testFontWeightClampsToValidRange() {
        XCTAssertEqual(MPVSubtitleStyle(fontWeight: 1200).fontWeight, 900)
        XCTAssertEqual(MPVSubtitleStyle(fontWeight: -50).fontWeight, 100)
        XCTAssertEqual(MPVSubtitleStyle(fontWeight: 500).fontWeight, 500)
        XCTAssertEqual(MPVSubtitleStyle(fontWeight: Double.nan).fontWeight, 400)
        XCTAssertEqual(MPVSubtitleStyle(fontWeight: Double.infinity).fontWeight, 400)
    }

    func testLegacyBoldMapsToNumericWeight() {
        XCTAssertEqual(MPVSubtitleStyle(bold: true).fontWeight, 700)
        XCTAssertEqual(MPVSubtitleStyle(bold: false).fontWeight, 400)
        // 显式字重优先于兼容参数。
        XCTAssertEqual(MPVSubtitleStyle(bold: true, fontWeight: 500).fontWeight, 500)
        XCTAssertEqual(MPVSubtitleStyle(bold: true, fontWeight: 400).fontWeight, 400)
    }

    /// ASS 只有 `sub-bold` 两档，按最近可表示字重（400 / 700）降级。
    func testBoldIsDerivedFromWeightInBothDirections() {
        XCTAssertFalse(MPVSubtitleStyle(fontWeight: 400).bold)
        XCTAssertFalse(MPVSubtitleStyle(fontWeight: 500).bold)
        XCTAssertFalse(MPVSubtitleStyle(fontWeight: 549).bold)
        XCTAssertTrue(MPVSubtitleStyle(fontWeight: 550).bold)
        XCTAssertTrue(MPVSubtitleStyle(fontWeight: 700).bold)
        XCTAssertTrue(MPVSubtitleStyle(fontWeight: 900).bold)

        var style = MPVSubtitleStyle()
        style.bold = true
        XCTAssertEqual(style.fontWeight, 700)
        style.bold = false
        XCTAssertEqual(style.fontWeight, 400)
    }

    func testPresetsKeepExistingBoldSemantics() {
        XCTAssertEqual(MPVSubtitleStyle.defaultStyle.fontWeight, 400)
        XCTAssertFalse(MPVSubtitleStyle.defaultStyle.bold)
        XCTAssertEqual(MPVSubtitleStyle.large.fontWeight, 400)
        XCTAssertFalse(MPVSubtitleStyle.large.bold)
        XCTAssertEqual(MPVSubtitleStyle.highContrast.fontWeight, 700)
        XCTAssertTrue(MPVSubtitleStyle.highContrast.bold)
    }

    func testBridgeDictionaryCarriesWeightAndLegacyBold() {
        let values = MPVSubtitleStyle(fontWeight: 600).bridgeDictionary
        XCTAssertEqual((values["fontWeight"] as? NSNumber)?.doubleValue, 600)
        // 桥接仍提供 `bold`，保证 Temby/LuWu 既有读取路径不变。
        XCTAssertEqual((values["bold"] as? NSNumber)?.boolValue, true)

        let regular = MPVSubtitleStyle(fontWeight: 400).bridgeDictionary
        XCTAssertEqual((regular["fontWeight"] as? NSNumber)?.doubleValue, 400)
        XCTAssertEqual((regular["bold"] as? NSNumber)?.boolValue, false)
    }

    // MARK: - UIKit 字重映射

    func testUIFontWeightMappingIsMonotonic() {
        let weights: [Double] = [100, 200, 300, 400, 500, 600, 700, 800, 900]
        let mapped = weights.map { MPVSubtitleStyle(fontWeight: $0).uiFontWeight.rawValue }
        XCTAssertEqual(mapped, mapped.sorted())
        XCTAssertEqual(Set(mapped).count, mapped.count, "九档应各自可分辨")
        XCTAssertEqual(MPVSubtitleStyle(fontWeight: 400).uiFontWeight, .regular)
        XCTAssertEqual(MPVSubtitleStyle(fontWeight: 700).uiFontWeight, .bold)
        // 档位之间连续插值，而非只落到九个锚点。
        let interpolated = MPVSubtitleStyle(fontWeight: 450).uiFontWeight.rawValue
        XCTAssertGreaterThan(interpolated, MPVSubtitleStyle(fontWeight: 400).uiFontWeight.rawValue)
        XCTAssertLessThan(interpolated, MPVSubtitleStyle(fontWeight: 500).uiFontWeight.rawValue)
    }

    // MARK: - 持久化

    func testLegacyBoldPreferenceMigratesToWeight() throws {
        let name = "MPVSubtitleFontWeightTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        // 历史数据只有 `bold`，没有 `fontWeight`。
        defaults.set([
            "fontSize": 46.0,
            "bold": true,
            "outlineSize": 1.0,
        ], forKey: "MPVQuickPlayer.subtitleSharedStyle")

        let style = MPVQuickPlayerSubtitlePreferences.style(defaults: defaults)
        XCTAssertEqual(style.fontWeight, 700)
        XCTAssertEqual(style.fontSize, 46)
        XCTAssertTrue(style.bold)
    }

    func testWeightPreferenceRoundTrips() throws {
        let name = "MPVSubtitleFontWeightTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        var style = MPVSubtitleStyle.highContrast
        style.fontWeight = 500
        MPVQuickPlayerSubtitlePreferences.save(style, defaults: defaults)
        let restored = MPVQuickPlayerSubtitlePreferences.style(defaults: defaults)
        XCTAssertEqual(restored, style)
        XCTAssertEqual(restored.fontWeight, 500)
    }

    // MARK: - 桥接层

    @MainActor
    func testBridgePrefersWeightOverLegacyBold() async {
        let playerView = MPVPlayerView(frame: .zero)
        let transfer = WeightTransfer(value: playerView)
        playerView.updateSubtitleStyle(["fontWeight": 500, "bold": true])

        // `sub-bold` 由数值字重决定，而不是被兼容参数覆盖。
        let nativeBold = await onMPVQueue(transfer) { $0.subtitleStyleValues[MPVProperty.subtitleBold] }
        XCTAssertEqual(nativeBold, "no")
        XCTAssertEqual(playerView.clientSubtitleController.style.fontWeight, 500)
    }

    @MainActor
    func testBridgeFallsBackToLegacyBoldWhenWeightMissing() async {
        let playerView = MPVPlayerView(frame: .zero)
        let transfer = WeightTransfer(value: playerView)
        playerView.updateSubtitleStyle(["bold": true])

        let nativeBold = await onMPVQueue(transfer) { $0.subtitleStyleValues[MPVProperty.subtitleBold] }
        XCTAssertEqual(nativeBold, "yes")
        XCTAssertEqual(playerView.clientSubtitleController.style.fontWeight, 700)
    }

    @MainActor
    func testNativeSubBoldIsThresholdedFromWeight() async {
        for (weight, expected) in [(400, "no"), (500, "no"), (600, "yes"), (700, "yes"), (900, "yes")] {
            let playerView = MPVPlayerView(frame: .zero)
            let transfer = WeightTransfer(value: playerView)
            playerView.updateSubtitleStyle(["fontWeight": weight])
            let actual = await onMPVQueue(transfer) { $0.subtitleStyleValues[MPVProperty.subtitleBold] }
            XCTAssertEqual(actual, expected, "fontWeight=\(weight)")
        }
    }

    // MARK: - 渲染层

    @MainActor
    func testRendererAppliesResolvedFontWeight() throws {
        let renderer = MPVDefaultSubtitleRenderer()
        renderer.view.frame = CGRect(x: 0, y: 0, width: 720, height: 720)
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Weight")],
            style: MPVSubtitleStyle(fontSize: 64, textColor: "#FFFFFFFF", fontWeight: 700)
        ))
        renderer.view.layoutIfNeeded()
        let label = try XCTUnwrap(renderer.view.subviews.compactMap { $0 as? UILabel }.first)
        let font = try XCTUnwrap(label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(Self.resolvedWeight(of: font), 0.4, accuracy: 0.001)
    }

    @MainActor
    func testWeightedRenderingInkGrowsWithWeight() throws {
        let renderer = MPVDefaultSubtitleRenderer()
        renderer.view.frame = CGRect(x: 0, y: 0, width: 720, height: 720)

        func inkPixels(weight: Double) throws -> Int {
            renderer.render(MPVSubtitlePresentation(
                cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle Weight")],
                style: MPVSubtitleStyle(fontSize: 64, textColor: "#FFFFFFFF", fontWeight: weight)
            ))
            renderer.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: renderer.view.bounds, format: format).image { context in
                renderer.view.layer.render(in: context.cgContext)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            let data = try XCTUnwrap(cgImage.dataProvider?.data)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
            var white = 0
            for y in 0..<cgImage.height {
                for x in 0..<cgImage.width {
                    let offset = y * cgImage.bytesPerRow + x * 4
                    if bytes[offset] > 220 && bytes[offset + 1] > 220 && bytes[offset + 2] > 220 { white += 1 }
                }
            }
            return white
        }

        let weights: [Double] = [100, 200, 300, 400, 500, 600, 700, 800, 900]
        var pixels: [Double: Int] = [:]
        for weight in weights { pixels[weight] = try inkPixels(weight: weight) }

        XCTAssertGreaterThan(pixels[400] ?? 0, 100)
        // 全档位墨量非递减；常用档位（含 SRT 实际可选区间）必须严格可分辨。
        for (lower, upper) in zip(weights, weights.dropFirst()) {
            XCTAssertLessThanOrEqual(pixels[lower] ?? 0, pixels[upper] ?? 0, "\(lower)→\(upper) 墨量应非递减")
        }
        for (lower, upper) in [(400.0, 500.0), (500.0, 600.0), (600.0, 700.0), (700.0, 900.0)] {
            XCTAssertLessThan(pixels[lower] ?? 0, pixels[upper] ?? 0, "\(lower)→\(upper) 墨量应严格递增")
        }
        XCTAssertGreaterThan(pixels[900] ?? 0, Int(Double(pixels[400] ?? 0) * 1.2))
    }

    // MARK: - Helper

    // MARK: - 设置面板

    @MainActor
    func testWeightSegmentAppliesAndReflectsStyle() throws {
        let panel = MPVQuickPlayerSubtitleSettingsView(frame: .zero)
        let control = try XCTUnwrap(panel.contentStack.arrangedSubviews
            .flatMap { $0.subviews }.compactMap { $0 as? UISegmentedControl }
            .first { $0.accessibilityIdentifier == "MPVQuickPlayer.subtitleWeight" })
        XCTAssertEqual(control.numberOfSegments, 5)

        var changed: MPVSubtitleStyle?
        panel.onStyleChange = { changed = $0 }

        // 宿主写入的非档位数值应就近显示为最近档位。
        panel.update(style: MPVSubtitleStyle(fontWeight: 620), delay: 0)
        XCTAssertEqual(control.selectedSegmentIndex, 2)

        // 本环境下 UISegmentedControl.sendActions 不派发事件（既有 `MPVSubtitleStyleTests`
        // 的阴影滑块用例同样受影响），因此直接驱动面板的处理函数。
        control.selectedSegmentIndex = 4
        panel.weightChanged(control)
        XCTAssertEqual(changed?.fontWeight, 900)
        XCTAssertTrue(changed?.bold ?? false)

        control.selectedSegmentIndex = 0
        panel.weightChanged(control)
        XCTAssertEqual(changed?.fontWeight, 400)
        XCTAssertFalse(changed?.bold ?? true)
    }

    func testWeightSegmentMappingRoundTrips() {
        let segments = MPVQuickPlayerSubtitleSettingsView.weightSegments
        XCTAssertEqual(segments, [400, 500, 600, 700, 900])
        for (index, weight) in segments.enumerated() {
            XCTAssertEqual(MPVQuickPlayerSubtitleSettingsView.weight(at: index), weight)
            XCTAssertEqual(MPVQuickPlayerSubtitleSettingsView.weightIndex(for: weight), index)
        }
        XCTAssertNil(MPVQuickPlayerSubtitleSettingsView.weight(at: segments.count))
        // 非档位数值就近归位。
        XCTAssertEqual(MPVQuickPlayerSubtitleSettingsView.weightIndex(for: 100), 0)
        XCTAssertEqual(MPVQuickPlayerSubtitleSettingsView.weightIndex(for: 540), 1)
        XCTAssertEqual(MPVQuickPlayerSubtitleSettingsView.weightIndex(for: 620), 2)
        // 800 与 700/900 等距，取先出现的 700
        XCTAssertEqual(MPVQuickPlayerSubtitleSettingsView.weightIndex(for: 800), 3)
        XCTAssertEqual(MPVQuickPlayerSubtitleSettingsView.weightIndex(for: 1000), 4)
    }

    private static func resolvedWeight(of font: UIFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat) ?? 0
    }

    @MainActor
    private func onMPVQueue<T: Sendable>(
        _ transfer: WeightTransfer<MPVPlayerView>,
        _ body: @escaping @Sendable (MPVPlayerView) -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            transfer.value.queue.async {
                continuation.resume(returning: body(transfer.value))
            }
        }
    }
}

private struct WeightTransfer<Value>: @unchecked Sendable {
    let value: Value
}
