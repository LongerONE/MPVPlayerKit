import XCTest
import UIKit
@testable import MPVPlayerKit

final class MPVPictureInPictureTests: XCTestCase {
    func testPictureInPictureContentSizeUsesVideoDisplaySizeAndFallback() {
        XCTAssertEqual(
            MPVPictureInPictureContentSize.resolve(
                videoDisplaySize: CGSize(width: 1440, height: 1080)
            ),
            CGSize(width: 1440, height: 1080)
        )
        XCTAssertEqual(
            MPVPictureInPictureContentSize.resolve(
                videoDisplaySize: CGSize(width: 1920, height: 800)
            ),
            CGSize(width: 1920, height: 800)
        )
        XCTAssertEqual(
            MPVPictureInPictureContentSize.resolve(videoDisplaySize: .zero),
            MPVPictureInPictureContentSize.fallback
        )
    }

    @MainActor
    func testPictureInPicturePreferredContentSizeIgnoresPlayerBoundsAfterVideoReconfig() {
        let playerView = MPVPlayerView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))

        XCTAssertEqual(
            playerView.pictureInPicturePreferredContentSize,
            MPVPictureInPictureContentSize.fallback
        )

        playerView.updatePictureInPictureVideoDisplaySize(
            CGSize(width: 1440, height: 1080)
        )

        XCTAssertEqual(
            playerView.pictureInPicturePreferredContentSize,
            CGSize(width: 1440, height: 1080)
        )
    }

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

    func testPictureInPictureFrameUpdatesOnlyWhileStartingOrActive() {
        XCTAssertTrue(MPVPictureInPictureFrameUpdatePolicy.shouldKeepUpdating(
            isActive: true,
            isStarting: false,
            isWaitingForStart: false
        ))
        XCTAssertTrue(MPVPictureInPictureFrameUpdatePolicy.shouldKeepUpdating(
            isActive: false,
            isStarting: true,
            isWaitingForStart: false
        ))
        XCTAssertTrue(MPVPictureInPictureFrameUpdatePolicy.shouldKeepUpdating(
            isActive: false,
            isStarting: false,
            isWaitingForStart: true
        ))
        XCTAssertFalse(MPVPictureInPictureFrameUpdatePolicy.shouldKeepUpdating(
            isActive: false,
            isStarting: false,
            isWaitingForStart: false
        ))
    }

    func testCancellingAnInProgressStartStopsTheSystemStartAndSuppressesInactiveState() {
        XCTAssertTrue(MPVPictureInPictureStartCancellationPolicy.shouldStopSystemController(
            isStarting: true
        ))
        XCTAssertFalse(MPVPictureInPictureStartCancellationPolicy.shouldStopSystemController(
            isStarting: false
        ))
        XCTAssertFalse(MPVPictureInPictureStartCancellationPolicy.shouldPostInactiveState(
            hasPostedActiveState: false,
            isStartCancellationRequested: true
        ))
    }

    func testFirstStartFailureDoesNotPublishInactiveState() {
        XCTAssertFalse(MPVPictureInPictureStartCancellationPolicy.shouldPostInactiveState(
            hasPostedActiveState: false,
            isStartCancellationRequested: false
        ))
    }

    func testStoppingAnActivePictureInPicturePublishesInactiveState() {
        XCTAssertTrue(MPVPictureInPictureStartCancellationPolicy.shouldPostInactiveState(
            hasPostedActiveState: true,
            isStartCancellationRequested: false
        ))
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
        XCTAssertEqual(sharedOptions["blend-subtitles"], "video")
        XCTAssertEqual(sharedOptions["sub-hdr-peak"], "100")
        XCTAssertEqual(sharedOptions["image-subs-hdr-peak"], "100")
        XCTAssertNil(sharedOptions["screenshot-sw"])
        XCTAssertNil(sharedOptions["target-colorspace-hint"])
        XCTAssertEqual(edrOptions["target-colorspace-hint"], "yes")
        XCTAssertEqual(edrOptions["target-colorspace-hint-mode"], "source")
        XCTAssertEqual(edrOptions["sub-hdr-peak"], "100")
        XCTAssertEqual(edrOptions["image-subs-hdr-peak"], "100")
        XCTAssertEqual(dolbyVisionOptions["target-colorspace-hint"], "yes")
        XCTAssertEqual(dolbyVisionOptions["target-colorspace-hint-mode"], "source-dynamic")
        XCTAssertEqual(dolbyVisionOptions["sub-hdr-peak"], "100")
        XCTAssertEqual(dolbyVisionOptions["image-subs-hdr-peak"], "100")
        XCTAssertEqual(sdrOptions["target-trc"], "srgb")
        XCTAssertEqual(sdrOptions["target-prim"], "bt.709")
        XCTAssertEqual(sdrOptions["sub-hdr-peak"], "100")
        XCTAssertEqual(sdrOptions["image-subs-hdr-peak"], "100")

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
