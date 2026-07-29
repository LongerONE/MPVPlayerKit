import XCTest
import UIKit
@testable import MPVPlayerKit

final class MPVSubtitleStyleTests: XCTestCase {
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
