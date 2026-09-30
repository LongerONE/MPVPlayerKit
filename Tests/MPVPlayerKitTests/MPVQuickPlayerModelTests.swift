import UIKit
import XCTest
@testable import MPVPlayerKit

final class MPVQuickPlayerModelTests: XCTestCase {
    @MainActor
    func testQuickPlayerSeekGestureUsesStableDurationRelativeSensitivity() {
        XCTAssertEqual(
            MPVQuickPlayerViewController.seekTimeDelta(
                translationX: 160,
                viewWidth: 320,
                duration: 7_200
            ),
            300,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MPVQuickPlayerViewController.seekTimeDelta(
                translationX: -160,
                viewWidth: 320,
                duration: 300
            ),
            -30,
            accuracy: 0.001
        )
    }

    @MainActor
    func testQuickPlayerVerticalGestureClampsToValidSystemRange() {
        XCTAssertEqual(
            MPVQuickPlayerViewController.verticalValue(
                startValue: 0.5,
                translationY: -200,
                viewHeight: 400
            ),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MPVQuickPlayerViewController.verticalValue(
                startValue: 0.5,
                translationY: 200,
                viewHeight: 400
            ),
            0,
            accuracy: 0.001
        )
    }

    @MainActor
    func testQuickPlayerOnlyShowsLoadingIndicatorWhileBuffering() {
        XCTAssertTrue(MPVQuickPlayerViewController.shouldShowLoading(for: .buffering))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .readyToPlay))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .bufferFinished))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .paused))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .playedToTheEnd))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .error))
    }

    @MainActor
    func testQuickPlayerExposesConfigurationAndRuntimeSettings() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let controller = MPVQuickPlayerViewController(
            configuration: MPVPlayerConfiguration(
                url: url,
                videoQuality: .highQuality,
                debandEnabled: true
            ),
            autoplay: false
        )

        XCTAssertEqual(controller.videoQuality, .highQuality)
        XCTAssertTrue(controller.debandEnabled)
        XCTAssertTrue(controller.prefersStatusBarHidden)
        XCTAssertEqual(controller.preferredStatusBarUpdateAnimation, .fade)
        XCTAssertTrue(controller.modalPresentationCapturesStatusBarAppearance)

        controller.setPlaybackRate(1.5)
        controller.setVideoQuality(.powerSaving)
        controller.setDebandEnabled(false)
        controller.setSubtitleDelay(90)
        controller.setSubtitleStyle(.highContrast)

        XCTAssertEqual(controller.playbackRate, 1.5)
        XCTAssertEqual(controller.videoQuality, .powerSaving)
        XCTAssertFalse(controller.debandEnabled)
        XCTAssertEqual(controller.subtitleDelay, 60)
        XCTAssertEqual(controller.subtitleStyle, .highContrast)
    }

    @MainActor
    func testQuickPlayerUsesAvailableSFSymbolControls() {
        MPVQuickPlayerSymbol.allCases.forEach { symbol in
            let image = UIImage(systemName: symbol.rawValue)
            XCTAssertNotNil(image, symbol.rawValue)
            XCTAssertEqual(
                MPVQuickPlayerSymbol.image(symbol)?.renderingMode,
                .alwaysTemplate,
                symbol.rawValue
            )
        }
    }

    @MainActor
    func testQuickPlayerSettingTitlesAreStable() {
        XCTAssertEqual(MPVQuickPlayerViewController.rateTitle(1.25), "1.25×")
        XCTAssertEqual(
            MPVQuickPlayerViewController.videoQualityTitle(.balanced, localization: "en"),
            "Balanced"
        )
        XCTAssertEqual(
            MPVQuickPlayerViewController.videoQualityTitle(.balanced, localization: "zh-Hans"),
            "均衡"
        )
        XCTAssertEqual(
            MPVQuickPlayerViewController.delayTitle(-0.5, localization: "en"),
            "-0.5s"
        )
        XCTAssertEqual(
            MPVQuickPlayerViewController.delayTitle(-0.5, localization: "zh-Hans"),
            "-0.5秒"
        )
    }
}
