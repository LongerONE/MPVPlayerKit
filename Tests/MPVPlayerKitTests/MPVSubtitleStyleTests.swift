import XCTest
import UIKit
@testable import MPVPlayerKit

final class MPVSubtitleStyleTests: XCTestCase {
    func testBoldSubtitleUsesHeavierBundledFont() {
        XCTAssertEqual(MPVSubtitleFont.name(isBold: false), MPVSubtitleFont.regular)
        XCTAssertEqual(MPVSubtitleFont.name(isBold: true), MPVSubtitleFont.bold)
        XCTAssertEqual(MPVSubtitleFont.bold, "NotoSansCJKjp-Bold")
    }

    func testImageSubtitleCodecRecognizesSUP() {
        XCTAssertTrue(MPVPlayerView.isImageSubtitleCodec("sup"))
        XCTAssertTrue(MPVPlayerView.isImageSubtitleCodec("hdmv_pgs_subtitle"))
        XCTAssertFalse(MPVPlayerView.isImageSubtitleCodec("subrip"))
    }

    func testShadowRadiusDefaultsClampsAndBridges() {
        XCTAssertEqual(MPVSubtitleStyle().shadowRadius, 0)
        XCTAssertEqual(MPVSubtitleStyle(shadowRadius: -1).shadowRadius, 0)
        XCTAssertEqual(MPVSubtitleStyle(shadowRadius: 21).shadowRadius, 20)
        XCTAssertEqual(MPVSubtitleStyle(shadowRadius: .nan).shadowRadius, 0)
        XCTAssertEqual(MPVSubtitleStyle(shadowRadius: .infinity).shadowRadius, 0)
        let style = MPVSubtitleStyle(shadowRadius: 8)
        XCTAssertEqual(style.bridgeDictionary["shadowRadius"] as? Double, 8)
        XCTAssertNotEqual(style, MPVSubtitleStyle())
    }

    @MainActor
    func testShadowSliderAppliesStrengthAndRestoresLegacyOffset() {
        let panel = MPVQuickPlayerSubtitleSettingsView(frame: .zero)
        guard let slider = panel.contentStack.arrangedSubviews
            .flatMap({ $0.subviews }).compactMap({ $0 as? UISlider }).first else {
            return XCTFail("Subtitle settings should contain a shadow slider")
        }
        panel.update(style: MPVSubtitleStyle(shadowRadius: 6), delay: 0)
        var changedStyle: MPVSubtitleStyle?
        panel.onStyleChange = { changedStyle = $0 }
        slider.value = 50
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(changedStyle?.shadowRadius, 6)
        XCTAssertEqual(changedStyle?.shadowOffset, 2)
        XCTAssertEqual(changedStyle?.shadowColor, "#93000000")
        slider.value = 100
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(changedStyle?.shadowRadius, 6)
        XCTAssertEqual(changedStyle?.shadowOffset, 4)
        XCTAssertEqual(changedStyle?.shadowColor, "#FF000000")
        slider.value = 0
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(changedStyle?.shadowRadius, 6)
        XCTAssertEqual(changedStyle?.shadowOffset, 0)
        XCTAssertEqual(changedStyle?.shadowColor, "#00000000")
        panel.update(style: MPVSubtitleStyle(shadowRadius: 6), delay: 0)
        XCTAssertEqual(slider.value, 0)
        panel.update(style: MPVSubtitleStyle(shadowOffset: 1), delay: 0)
        XCTAssertEqual(slider.value, 25)
        let radius = panel.contentStack.arrangedSubviews.flatMap { $0.subviews }
            .compactMap { $0 as? UISlider }.first { $0.accessibilityIdentifier == "MPVQuickPlayer.subtitleShadowRadius" }!
        radius.value = 7.3
        radius.sendActions(for: .valueChanged)
        XCTAssertEqual(changedStyle?.shadowRadius, 7.5)
        XCTAssertEqual(changedStyle?.shadowOffset, 1)
        radius.value = 0
        radius.sendActions(for: .valueChanged)
        XCTAssertEqual(changedStyle?.shadowOffset, 1)
        XCTAssertEqual(changedStyle?.shadowRadius, 0)
        XCTAssertTrue(radius.isContinuous)
        panel.isShadowRadiusEditable = false
        XCTAssertFalse(radius.isEnabled)
    }

    @MainActor
    func testRendererAppliesShadowRadiusWithExistingOpacity() {
        let renderer = MPVDefaultSubtitleRenderer()
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: MPVSubtitleStyle(shadowOffset: 2, shadowRadius: 4)
        ))
        guard let label = renderer.view.subviews.compactMap({ $0 as? UILabel }).first else {
            return XCTFail("Renderer should create a subtitle label")
        }
        XCTAssertEqual(label.layer.shadowRadius, 4)
        XCTAssertEqual(label.layer.shadowOpacity, 0.6)
        XCTAssertEqual(label.layer.shadowOffset, CGSize(width: 0, height: 2))
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: MPVSubtitleStyle(shadowOffset: 2, shadowRadius: 12.5)
        ))
        XCTAssertEqual(label.layer.shadowRadius, 12.5)
        XCTAssertEqual(label.layer.shadowOffset, CGSize(width: 0, height: 2))
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: MPVSubtitleStyle(shadowOffset: 2, shadowRadius: 0)
        ))
        XCTAssertEqual(label.layer.shadowRadius, 0)
        XCTAssertEqual(label.layer.shadowOpacity, 0.6)
    }

    func testSubtitleStyleCarriesCustomFontName() {
        let style = MPVSubtitleStyle(fontName: "Example-Regular")
        XCTAssertEqual(style.fontName, "Example-Regular")
        XCTAssertEqual(style.bridgeDictionary["fontName"] as? String, "Example-Regular")
    }

    func testSubtitleStyleResolvesShadowColorForCurrentAndLegacyDictionaries() {
        XCTAssertEqual(
            MPVPlayerView.subtitleShadowColor(
                from: ["shadowColor": "#FF112233", "backgroundColor": "#00000000"],
                shadowOffset: 2
            ),
            "#FF112233"
        )
        XCTAssertEqual(
            MPVPlayerView.subtitleShadowColor(
                from: ["backgroundColor": "#80010203"],
                shadowOffset: 2
            ),
            "#80010203"
        )
        XCTAssertEqual(
            MPVPlayerView.subtitleShadowColor(
                from: ["backgroundColor": "#00010203"],
                shadowOffset: 2
            ),
            "#FF000000"
        )
        XCTAssertEqual(
            MPVPlayerView.subtitleShadowColor(from: [:], shadowOffset: 0),
            "#FF000000"
        )
    }

    @MainActor
    func testNativeSubtitleStyleAlwaysResetsGlyphBlur() async {
        let playerView = MPVPlayerView(frame: .zero)
        let transfer = UnsafeTransfer(value: playerView)
        playerView.updateSubtitleStyle([
            "shadowOffset": 2,
            "shadowBlur": 8,
        ])

        let blurValue: String? = await withCheckedContinuation { continuation in
            playerView.queue.async {
                continuation.resume(
                    returning: transfer.value.subtitleStyleValues[MPVProperty.subtitleBlur]
                )
            }
        }
        XCTAssertEqual(blurValue, "0.000")
    }

    @MainActor
    func testDefaultSubtitleRendererSeparatesShadowAndBackgroundColors() {
        let renderer = MPVDefaultSubtitleRenderer()
        let style = MPVSubtitleStyle(
            shadowOffset: 2,
            backgroundColor: "#80010203",
            shadowColor: "#FF102030"
        )
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: style
        ))

        guard let label = renderer.view.subviews.compactMap({ $0 as? UILabel }).first,
              let shadowCGColor = label.layer.shadowColor,
              let backgroundColor = label.attributedText?.attribute(
                  .backgroundColor,
                  at: 0,
                  effectiveRange: nil
              ) as? UIColor else {
            return XCTFail("Renderer should apply both subtitle colors")
        }
        assertColor(UIColor(cgColor: shadowCGColor), red: 0x10, green: 0x20, blue: 0x30, alpha: 0xFF)
        assertColor(backgroundColor, red: 0x01, green: 0x02, blue: 0x03, alpha: 0x80)
        XCTAssertEqual(label.layer.shadowOpacity, 0.6)
        XCTAssertEqual(label.layer.shadowRadius, 0)
    }

    @MainActor
    func testDefaultSubtitleRendererUsesOffsetWithoutBlurRadius() {
        let renderer = MPVDefaultSubtitleRenderer()
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: MPVSubtitleStyle(shadowOffset: 10)
        ))

        guard let label = renderer.view.subviews.compactMap({ $0 as? UILabel }).first else {
            return XCTFail("Renderer should create a subtitle label")
        }
        XCTAssertEqual(label.layer.shadowRadius, 0)
        XCTAssertEqual(label.layer.shadowOffset, CGSize(width: 0, height: 10))
    }

    @MainActor
    func testDefaultSubtitleRendererClearsShadowLayerWhenDisabled() {
        let renderer = MPVDefaultSubtitleRenderer()
        renderer.render(MPVSubtitlePresentation(
            cues: [MPVSubtitleCue(startTime: 0, endTime: 1, text: "Subtitle")],
            style: MPVSubtitleStyle(shadowOffset: 0)
        ))

        guard let label = renderer.view.subviews.compactMap({ $0 as? UILabel }).first else {
            return XCTFail("Renderer should create a subtitle label")
        }
        XCTAssertEqual(label.layer.shadowOpacity, 0)
        XCTAssertEqual(label.layer.shadowRadius, 0)
        XCTAssertEqual(label.layer.shadowOffset, .zero)
    }

    private func assertColor(
        _ color: UIColor,
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var actualRed: CGFloat = 0
        var actualGreen: CGFloat = 0
        var actualBlue: CGFloat = 0
        var actualAlpha: CGFloat = 0
        XCTAssertTrue(
            color.getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &actualAlpha),
            file: file,
            line: line
        )
        XCTAssertEqual(actualRed, CGFloat(red) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualGreen, CGFloat(green) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualBlue, CGFloat(blue) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actualAlpha, CGFloat(alpha) / 255, accuracy: 0.001, file: file, line: line)
    }
}

private struct UnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
}
