import XCTest
import UIKit
import Metal
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

    func testPictureInPictureUsesCompatibleRawScreenshotArguments() {
        XCTAssertEqual(
            MPVPlayerView.pictureInPictureScreenshotArgumentCandidates,
            [["video", "bgra"], ["video"]]
        )
    }

    func testRendererInvariantOptionMapUsesLastValueForDuplicateKeys() {
        XCTAssertEqual(
            MPVPictureInPictureRendererInvariantSnapshot.optionMap([
                ("target-colorspace-hint-mode", "source"),
                ("target-colorspace-hint-mode", "source-dynamic"),
            ])["target-colorspace-hint-mode"],
            "source-dynamic"
        )
    }

    @MainActor
    func testStopClearsPictureInPictureRendererRuntimeState() {
        let playerView = MPVPlayerView(frame: .zero)
        playerView.pictureInPictureRendererRuntimeState.store(
            profiles: [
                .init(MPVSetupProfile(name: "test", options: [("vo", "gpu-next")])),
            ],
            activeProfileIndex: 0
        )

        playerView.stop()

        let snapshot = playerView.pictureInPictureRendererInvariantSnapshot()
        XCTAssertTrue(snapshot.runtimeSetupProfiles.isEmpty)
        XCTAssertEqual(snapshot.runtimeActiveSetupProfileIndex, 0)
    }

    @MainActor
    func testRepeatedStopClearsPictureInPictureRendererRuntimeState() {
        let playerView = MPVPlayerView(frame: .zero)
        playerView.stopped = true
        playerView.pictureInPictureRendererRuntimeState.store(
            profiles: [
                .init(MPVSetupProfile(name: "test", options: [("vo", "gpu-next")])),
            ],
            activeProfileIndex: 0
        )

        playerView.stop()

        let snapshot = playerView.pictureInPictureRendererInvariantSnapshot()
        XCTAssertTrue(snapshot.runtimeSetupProfiles.isEmpty)
        XCTAssertEqual(snapshot.runtimeActiveSetupProfileIndex, 0)
    }

    @MainActor
    func testFinalSetupFailureClearsPictureInPictureRendererRuntimeState() {
        let playerView = MPVPlayerView(frame: .zero)
        playerView.pictureInPictureRendererRuntimeState.store(
            profiles: [
                .init(MPVSetupProfile(name: "test", options: [("vo", "gpu-next")])),
            ],
            activeProfileIndex: 0
        )

        playerView.failSetup()

        let snapshot = playerView.pictureInPictureRendererInvariantSnapshot()
        XCTAssertTrue(snapshot.runtimeSetupProfiles.isEmpty)
        XCTAssertEqual(snapshot.runtimeActiveSetupProfileIndex, 0)
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
    func testPictureInPictureRendererInvariantSnapshotProtectsEDRLayerAndProfiles() {
        let playerView = MPVPlayerView(frame: .zero)
        let snapshot = playerView.pictureInPictureRendererInvariantSnapshot()
        let sharedOptions = MPVPictureInPictureRendererInvariantSnapshot.optionMap(
            MPVPlayerView.sharedMetalVideoOutputOptions
        )
        let edrOptions = MPVPictureInPictureRendererInvariantSnapshot.optionMap(
            MPVPlayerView.edrMetalVideoOutputOptions
        )
        let dolbyVisionOptions = MPVPictureInPictureRendererInvariantSnapshot.optionMap(
            MPVPlayerView.dolbyVisionEDRMetalVideoOutputOptions
        )
        let sdrOptions = MPVPictureInPictureRendererInvariantSnapshot.optionMap(
            MPVPlayerView.sdrMetalVideoOutputOptions
        )

        XCTAssertEqual(sharedOptions["vo"], "gpu-next")
        XCTAssertEqual(sharedOptions["gpu-api"], "vulkan")
        XCTAssertEqual(sharedOptions["gpu-context"], "moltenvk")
        XCTAssertEqual(sharedOptions["blend-subtitles"], "video")
        XCTAssertEqual(sharedOptions["sub-hdr-peak"], "100")
        XCTAssertEqual(sharedOptions["image-subs-hdr-peak"], "100")
        XCTAssertNil(sharedOptions["screenshot-sw"])
        XCTAssertNil(sharedOptions["target-colorspace-hint"])
        XCTAssertTrue(snapshot.runtimeSetupProfiles.isEmpty)
        XCTAssertEqual(snapshot.runtimeActiveSetupProfileIndex, 0)
        XCTAssertEqual(
            snapshot.selectedVideoOutputOptions,
            MPVPictureInPictureRendererInvariantSnapshot.optionMap(
                playerView.metalVideoOutputOptions
            )
        )
        XCTAssertTrue(snapshot.metalFramebufferOnly)
        XCTAssertEqual(snapshot.metalLayerIdentifier, ObjectIdentifier(playerView.metalLayer))
        XCTAssertEqual(
            snapshot.metalLayerSuperlayerIdentifier,
            playerView.metalLayer.superlayer.map(ObjectIdentifier.init)
        )
        XCTAssertEqual(edrOptions["target-colorspace-hint"], "yes")
        XCTAssertEqual(edrOptions["target-colorspace-hint-mode"], "source")
        XCTAssertEqual(edrOptions["sub-hdr-peak"], "100")
        XCTAssertEqual(edrOptions["image-subs-hdr-peak"], "100")
        XCTAssertNil(edrOptions["target-trc"])
        XCTAssertNil(edrOptions["target-prim"])
        XCTAssertEqual(dolbyVisionOptions["target-colorspace-hint"], "yes")
        XCTAssertEqual(dolbyVisionOptions["target-colorspace-hint-mode"], "source-dynamic")
        XCTAssertEqual(dolbyVisionOptions["sub-hdr-peak"], "100")
        XCTAssertEqual(dolbyVisionOptions["image-subs-hdr-peak"], "100")
        XCTAssertNil(dolbyVisionOptions["target-trc"])
        XCTAssertNil(dolbyVisionOptions["target-prim"])
        XCTAssertEqual(sdrOptions["target-trc"], "srgb")
        XCTAssertEqual(sdrOptions["target-prim"], "bt.709")
        XCTAssertEqual(sdrOptions["sub-hdr-peak"], "100")
        XCTAssertEqual(sdrOptions["image-subs-hdr-peak"], "100")
        XCTAssertNil(sdrOptions["fbo-format"])
        XCTAssertNil(sdrOptions["target-colorspace-hint"])
        XCTAssertNil(sdrOptions["target-colorspace-hint-mode"])

        #if targetEnvironment(simulator)
        XCTAssertFalse(playerView.usesExtendedDynamicRangeOutput)
        XCTAssertFalse(snapshot.usesExtendedDynamicRangeOutput)
        XCTAssertEqual(snapshot.metalPixelFormat, MTLPixelFormat.bgra8Unorm_srgb.rawValue)
        XCTAssertEqual(playerView.metalLayer.pixelFormat, .bgra8Unorm_srgb)
        XCTAssertEqual(playerView.metalLayer.colorspace?.name, CGColorSpace.sRGB)
        #else
        if #available(iOS 16.0, *) {
            XCTAssertTrue(playerView.usesExtendedDynamicRangeOutput)
            XCTAssertTrue(snapshot.usesExtendedDynamicRangeOutput)
            XCTAssertEqual(snapshot.metalPixelFormat, MTLPixelFormat.rgba16Float.rawValue)
            XCTAssertEqual(playerView.metalLayer.pixelFormat, .rgba16Float)
            XCTAssertEqual(playerView.metalLayer.colorspace?.name, CGColorSpace.extendedLinearSRGB)
            XCTAssertTrue(playerView.metalLayer.wantsExtendedDynamicRangeContent)
            XCTAssertTrue(snapshot.metalWantsExtendedDynamicRangeContent)
        }
        #endif
    }

    @MainActor
    func testPictureInPictureRendererInvariantSnapshotSelectsSDREDRAndDolbyVisionProfiles() {
        let playerView = MPVPlayerView(frame: .zero)

        playerView.usesExtendedDynamicRangeOutput = false
        playerView.isDolbyVisionPlayback = false
        XCTAssertRendererOptionsAndProfiles(
            playerView: playerView,
            expectedColorOptions: MPVPlayerView.sdrMetalVideoOutputOptions,
            expectedHintMode: nil
        )

        playerView.usesExtendedDynamicRangeOutput = true
        playerView.isDolbyVisionPlayback = false
        XCTAssertRendererOptionsAndProfiles(
            playerView: playerView,
            expectedColorOptions: MPVPlayerView.edrMetalVideoOutputOptions,
            expectedHintMode: "source"
        )

        playerView.isDolbyVisionPlayback = true
        XCTAssertRendererOptionsAndProfiles(
            playerView: playerView,
            expectedColorOptions: MPVPlayerView.dolbyVisionEDRMetalVideoOutputOptions,
            expectedHintMode: "source-dynamic"
        )
    }

    @MainActor
    private func XCTAssertRendererOptionsAndProfiles(
        playerView: MPVPlayerView,
        expectedColorOptions: [(String, String)],
        expectedHintMode: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let snapshot = playerView.pictureInPictureRendererInvariantSnapshot()
        let expectedOptions = MPVPictureInPictureRendererInvariantSnapshot.optionMap(
            expectedColorOptions
        )
        let setupProfileOptionMaps = playerView.makeSetupProfiles().map {
            MPVPictureInPictureRendererInvariantSnapshot.optionMap($0.options)
        }
        expectedOptions.forEach { name, value in
            XCTAssertEqual(
                snapshot.selectedVideoOutputOptions[name],
                value,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            snapshot.selectedVideoOutputOptions["target-colorspace-hint-mode"],
            expectedHintMode,
            file: file,
            line: line
        )
        XCTAssertTrue(setupProfileOptionMaps.allSatisfy {
            $0["target-colorspace-hint-mode"] == expectedHintMode
        }, file: file, line: line)
        XCTAssertFalse(setupProfileOptionMaps.isEmpty, file: file, line: line)
        XCTAssertTrue(snapshot.runtimeSetupProfiles.isEmpty, file: file, line: line)
    }
}
