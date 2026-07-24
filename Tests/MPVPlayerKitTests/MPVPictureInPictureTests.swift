import XCTest
import UIKit
@testable import MPVPlayerKit

final class MPVPictureInPictureTests: XCTestCase {
    @MainActor
    func testQuickPlayerExposesPictureInPictureControl() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let controller = MPVQuickPlayerViewController(url: url, autoplay: false)
        controller.loadViewIfNeeded()

        XCTAssertTrue(controller.trackButtonStack.arrangedSubviews.contains(controller.pictureInPictureButton))
        XCTAssertEqual(controller.pictureInPictureButton.accessibilityIdentifier, "MPVQuickPlayer.pictureInPictureButton")
        XCTAssertEqual(controller.pictureInPictureButton.isEnabled, controller.player.isPictureInPictureSupported)
        if controller.player.isPictureInPictureSupported {
            XCTAssertTrue(controller.preparePictureInPicturePlayback(activateAudioSession: {}))
            XCTAssertTrue(controller.player.allowsAutomaticPictureInPictureFromInline)
        }
    }

    @MainActor
    func testPictureInPictureMovesAndRestoresTheCompletePlayerView() throws {
        let inlineView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 219))
        let playerView = MPVPlayerView(frame: .zero)
        let pictureInPictureView = UIView(frame: inlineView.bounds)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        inlineView.addSubview(playerView)
        let leading = playerView.leadingAnchor.constraint(equalTo: inlineView.leadingAnchor)
        let trailing = playerView.trailingAnchor.constraint(equalTo: inlineView.trailingAnchor)
        let top = playerView.topAnchor.constraint(equalTo: inlineView.topAnchor)
        let bottom = playerView.bottomAnchor.constraint(equalTo: inlineView.bottomAnchor)
        NSLayoutConstraint.activate([leading, trailing, top, bottom])

        let placement = try XCTUnwrap(MPVPictureInPictureViewPlacement(playerView: playerView))
        let internalConstraints = playerView.constraints
        XCTAssertFalse(internalConstraints.isEmpty)
        placement.movePlayer(to: pictureInPictureView)
        XCTAssertTrue(playerView.superview === pictureInPictureView)
        XCTAssertFalse(leading.isActive)
        XCTAssertTrue(internalConstraints.allSatisfy(\.isActive))
        XCTAssertTrue(playerView.metalLayer.superlayer === playerView.layer)

        placement.restorePlayer()
        XCTAssertTrue(playerView.superview === inlineView)
        XCTAssertTrue(leading.isActive)
        XCTAssertTrue(playerView.metalLayer.superlayer === playerView.layer)
    }

    func testPictureInPictureStartCancellationPreventsViewMigration() {
        XCTAssertFalse(
            MPVPictureInPictureStartCancellationPolicy.shouldMovePlayer(
                isStarting: true,
                isActive: false,
                isCancellationRequested: true
            )
        )
        XCTAssertTrue(
            MPVPictureInPictureStartCancellationPolicy.shouldMovePlayer(
                isStarting: true,
                isActive: false,
                isCancellationRequested: false
            )
        )
        XCTAssertFalse(
            MPVPictureInPictureStartCancellationPolicy.shouldPostInactiveState(
                hasPostedActiveState: false,
                isStartCancellationRequested: true
            )
        )
        XCTAssertFalse(
            MPVPictureInPictureStartCancellationPolicy.shouldPostInactiveState(
                hasPostedActiveState: true,
                isStartCancellationRequested: true
            )
        )
        XCTAssertTrue(
            MPVPictureInPictureStartCancellationPolicy.shouldPostInactiveState(
                hasPostedActiveState: true,
                isStartCancellationRequested: false
            )
        )
    }

    @MainActor
    func testPictureInPictureDoesNotCloneInternalLayoutGuideConstraints() throws {
        let inlineView = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 219))
        let playerView = MPVPlayerView(frame: inlineView.bounds)
        let subtitleView = UIView()
        let customGuide = UILayoutGuide()
        playerView.addSubview(subtitleView)
        subtitleView.addLayoutGuide(customGuide)
        inlineView.addSubview(playerView)

        let safeAreaConstraint = playerView.leadingAnchor.constraint(
            equalTo: subtitleView.safeAreaLayoutGuide.leadingAnchor
        )
        let customGuideConstraint = playerView.trailingAnchor.constraint(
            equalTo: customGuide.trailingAnchor
        )
        NSLayoutConstraint.activate([safeAreaConstraint, customGuideConstraint])

        let placement = try XCTUnwrap(MPVPictureInPictureViewPlacement(playerView: playerView))
        placement.movePlayer(to: UIView(frame: inlineView.bounds))

        XCTAssertTrue(safeAreaConstraint.isActive)
        XCTAssertTrue(customGuideConstraint.isActive)
    }

    @MainActor
    func testMetalRendererPreservesEDRWithViewBasedPictureInPicture() {
        let playerView = MPVPlayerView(frame: .zero)
        let sharedOptions = Dictionary(uniqueKeysWithValues: MPVPlayerView.sharedMetalVideoOutputOptions)
        let edrOptions = Dictionary(uniqueKeysWithValues: MPVPlayerView.edrMetalVideoOutputOptions)
        let dolbyVisionOptions = Dictionary(uniqueKeysWithValues: MPVPlayerView.dolbyVisionEDRMetalVideoOutputOptions)
        let sdrOptions = Dictionary(uniqueKeysWithValues: MPVPlayerView.sdrMetalVideoOutputOptions)

        XCTAssertEqual(sharedOptions["vo"], "gpu-next")
        XCTAssertEqual(sharedOptions["gpu-api"], "vulkan")
        XCTAssertEqual(sharedOptions["gpu-context"], "moltenvk")
        XCTAssertNil(sharedOptions["screenshot-sw"])
        XCTAssertNil(sharedOptions["target-colorspace-hint"])
        XCTAssertEqual(edrOptions["target-colorspace-hint"], "yes")
        XCTAssertEqual(edrOptions["target-colorspace-hint-mode"], "source")
        XCTAssertEqual(dolbyVisionOptions["target-colorspace-hint"], "yes")
        XCTAssertEqual(dolbyVisionOptions["target-colorspace-hint-mode"], "source-dynamic")
        XCTAssertEqual(sdrOptions["target-trc"], "srgb")
        XCTAssertEqual(sdrOptions["target-prim"], "bt.709")

        #if targetEnvironment(simulator)
        XCTAssertFalse(playerView.usesExtendedDynamicRangeOutput)
        XCTAssertEqual(playerView.metalLayer.pixelFormat, .bgra8Unorm_srgb)
        XCTAssertEqual(playerView.metalLayer.colorspace?.name, CGColorSpace.sRGB)
        #else
        if #available(iOS 16.0, *) {
            XCTAssertTrue(playerView.usesExtendedDynamicRangeOutput)
            XCTAssertEqual(playerView.metalLayer.pixelFormat, .rgba16Float)
            XCTAssertEqual(playerView.metalLayer.colorspace?.name, CGColorSpace.extendedLinearSRGB)
            XCTAssertTrue(playerView.metalLayer.wantsExtendedDynamicRangeContent)
        }
        #endif
    }
}
