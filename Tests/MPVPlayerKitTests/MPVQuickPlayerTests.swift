import XCTest
import UIKit
@testable import MPVPlayerKit

final class MPVQuickPlayerTests: XCTestCase {
    func testQuickPlayerCanForceLandscapeWhenHostOnlySupportsPortrait() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let controller = MPVQuickPlayerViewController(url: url, autoplay: false, forceLandscape: true)

        XCTAssertTrue(controller.isLandscapeForced)
        XCTAssertFalse(MPVQuickPlayerViewController.supportsLandscape(orientationNames: ["UIInterfaceOrientationPortrait"]))
        XCTAssertTrue(MPVQuickPlayerViewController.supportsLandscape(orientationNames: ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeRight"]))

        controller.loadViewIfNeeded()
        controller.view.bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.isUsingManualLandscape = true
        controller.layoutOrientationContentView()

        XCTAssertEqual(controller.supportedInterfaceOrientations, .portrait)
        XCTAssertEqual(controller.preferredInterfaceOrientationForPresentation, .portrait)
        XCTAssertEqual(controller.contentView.bounds.width, 844)
        XCTAssertEqual(controller.contentView.bounds.height, 390)
        XCTAssertNotEqual(controller.contentView.transform, .identity)

        let rootStart = CGPoint(x: controller.view.bounds.midX, y: 100)
        let rootEnd = CGPoint(x: controller.view.bounds.midX, y: 220)
        let contentStart = controller.contentView.convert(rootStart, from: controller.view)
        let contentEnd = controller.contentView.convert(rootEnd, from: controller.view)
        XCTAssertGreaterThan(abs(contentEnd.x - contentStart.x), abs(contentEnd.y - contentStart.y))

        let manualInsets = MPVQuickPlayerViewController.playbackControlHorizontalInsets(
            rootBounds: controller.view.bounds,
            rootSafeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
            usesManualLandscape: true
        )
        XCTAssertEqual(manualInsets.left, 59)
        XCTAssertEqual(manualInsets.right, 34)

        let landscapeBounds = controller.contentView.bounds
        let landscapeCenter = controller.contentView.center
        let landscapeTransform = controller.contentView.transform
        controller.layoutOrientationContentView()
        XCTAssertEqual(controller.contentView.bounds, landscapeBounds)
        XCTAssertEqual(controller.contentView.center, landscapeCenter)
        XCTAssertEqual(controller.contentView.transform, landscapeTransform)

        controller.setForceLandscape(false)
        XCTAssertFalse(controller.isLandscapeForced)
        XCTAssertEqual(controller.supportedInterfaceOrientations, .all)
        XCTAssertEqual(controller.preferredInterfaceOrientationForPresentation, .portrait)
        XCTAssertEqual(controller.contentView.transform, .identity)
    }

    func testQuickPlayerCanHideAndRestorePlaybackControls() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let controller = MPVQuickPlayerViewController(url: url, autoplay: false)
        controller.loadViewIfNeeded()

        controller.setPlaybackControlsHidden(true, animated: false)
        XCTAssertTrue(controller.arePlaybackControlsHidden)
        XCTAssertEqual(controller.topBar.alpha, 0)
        XCTAssertEqual(controller.controlsView.alpha, 0)
        XCTAssertFalse(controller.topBar.isUserInteractionEnabled)
        XCTAssertFalse(controller.controlsView.isUserInteractionEnabled)

        controller.setPlaybackControlsHidden(false, animated: false)
        XCTAssertFalse(controller.arePlaybackControlsHidden)
        XCTAssertEqual(controller.topBar.alpha, 1)
        XCTAssertEqual(controller.controlsView.alpha, 1)
        XCTAssertTrue(controller.topBar.isUserInteractionEnabled)
        XCTAssertTrue(controller.controlsView.isUserInteractionEnabled)
    }

    @MainActor
    func testQuickPlayerExposesFifteenSecondTransportControls() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let controller = MPVQuickPlayerViewController(url: url, autoplay: false)
        controller.loadViewIfNeeded()

        XCTAssertEqual(
            controller.transportStack.arrangedSubviews,
            [controller.backwardButton, controller.playButton, controller.forwardButton]
        )
        XCTAssertEqual(
            controller.backwardButton.accessibilityIdentifier,
            "MPVQuickPlayer.backward15Button"
        )
        XCTAssertEqual(
            controller.playButton.accessibilityIdentifier,
            "MPVQuickPlayer.playButton"
        )
        XCTAssertEqual(
            controller.forwardButton.accessibilityIdentifier,
            "MPVQuickPlayer.forward15Button"
        )
        XCTAssertNotNil(controller.backwardButton.image(for: .normal))
        XCTAssertNotNil(controller.playButton.image(for: .normal))
        XCTAssertNotNil(controller.forwardButton.image(for: .normal))
        XCTAssertEqual(controller.backwardButton.accessibilityLabel, mpvLocalized("accessibility.skip_backward_15_seconds"))
        XCTAssertEqual(controller.forwardButton.accessibilityLabel, mpvLocalized("accessibility.skip_forward_15_seconds"))

        let backwardAction = NSStringFromSelector(#selector(MPVQuickPlayerViewController.skipBackward15Seconds))
        let forwardAction = NSStringFromSelector(#selector(MPVQuickPlayerViewController.skipForward15Seconds))
        XCTAssertTrue(
            controller.backwardButton.actions(forTarget: controller, forControlEvent: .touchUpInside)?.contains(backwardAction) == true
        )
        XCTAssertTrue(
            controller.forwardButton.actions(forTarget: controller, forControlEvent: .touchUpInside)?.contains(forwardAction) == true
        )
    }
}
