import XCTest
import CoreMedia
import UIKit
import Metal
@testable import MPVPlayerKit

final class MPVPictureInPictureTests: XCTestCase {

    private final class ReentrantLayoutView: UIView {
        var onLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

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

    /// The content view controller appears before the window is reported
    /// active, and it appears again on a start that is already being cancelled.
    /// Moving the player view then would strand it in a closing window.
    func testCancellingAnInProgressStartKeepsThePlayerViewInline() {
        XCTAssertTrue(MPVPictureInPictureStartCancellationPolicy.shouldMovePlayer(
            isStarting: true,
            isActive: false,
            isCancellationRequested: false,
            isStopping: false
        ))
        XCTAssertTrue(MPVPictureInPictureStartCancellationPolicy.shouldMovePlayer(
            isStarting: false,
            isActive: true,
            isCancellationRequested: false,
            isStopping: false
        ))
        XCTAssertFalse(MPVPictureInPictureStartCancellationPolicy.shouldMovePlayer(
            isStarting: true,
            isActive: false,
            isCancellationRequested: true,
            isStopping: false
        ))
        // AVKit still reports the controller as active while it lays out the
        // disappearing window. That pass must not move the restored player
        // back into the shrinking PiP container.
        XCTAssertFalse(MPVPictureInPictureStartCancellationPolicy.shouldMovePlayer(
            isStarting: false,
            isActive: true,
            isCancellationRequested: false,
            isStopping: true
        ))
        XCTAssertFalse(MPVPictureInPictureStartCancellationPolicy.shouldMovePlayer(
            isStarting: false,
            isActive: false,
            isCancellationRequested: false,
            isStopping: false
        ))
        XCTAssertFalse(MPVPictureInPictureStartCancellationPolicy.shouldPostInactiveState(
            hasPostedActiveState: false,
            isStartCancellationRequested: true
        ))
    }

    func testTeardownStopsAStartThatHasNotReachedTheWindowYet() {
        XCTAssertTrue(MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
            isStartCancellationRequested: false,
            isTearingDown: false
        ))
        XCTAssertFalse(MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
            isStartCancellationRequested: false,
            isTearingDown: true
        ))
        XCTAssertFalse(MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
            isStartCancellationRequested: true,
            isTearingDown: false
        ))
    }

    /// Hosting only works if the player view really moves and really comes
    /// back, with the inline layout undisturbed while it is away.
    @MainActor
    func testPlacementMovesThePlayerViewAndRestoresItsInlinePosition() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let sibling = UIView()
        let playerView = MPVPlayerView(frame: CGRect(x: 0, y: 100, width: 390, height: 220))
        container.addSubview(sibling)
        container.addSubview(playerView)
        let pictureInPictureContainer = UIView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )

        let placement = try XCTUnwrap(MPVPictureInPictureViewPlacement(playerView: playerView))
        XCTAssertFalse(placement.isPlayerInPictureInPictureContainer)
        // The anchor AVKit tracks stays behind, so the system keeps a stable
        // source rect while the player view is in the window.
        XCTAssertTrue(placement.sourceView.isDescendant(of: container))

        placement.movePlayer(to: pictureInPictureContainer)

        XCTAssertTrue(placement.isPlayerInPictureInPictureContainer)
        XCTAssertTrue(playerView.isDescendant(of: pictureInPictureContainer))
        XCTAssertFalse(playerView.isDescendant(of: container))
        XCTAssertTrue(placement.sourceView.isDescendant(of: container))

        placement.restorePlayer()

        XCTAssertFalse(placement.isPlayerInPictureInPictureContainer)
        XCTAssertTrue(playerView.isDescendant(of: container))
        XCTAssertEqual(container.subviews.firstIndex(of: playerView), 1)
        XCTAssertEqual(playerView.frame, container.bounds)

        placement.tearDown()

        XCTAssertFalse(placement.sourceView.isDescendant(of: container))
        XCTAssertTrue(playerView.isDescendant(of: container))
    }

    /// Returning from the window left the layer presenting the drawable it
    /// last produced at the Picture in Picture size, which put the video in a
    /// strip at the top of the restored view. The size matches the one applied
    /// before the window opened, so the ordinary change test skips it and MPV
    /// is never told to render at the inline size again.
    @MainActor
    func testGeometryResyncRecoversADrawableLeftAtThePictureInPictureSize() {
        let scale = UIScreen.main.nativeScale
        let playerView = MPVPlayerView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        playerView.updateMetalLayerGeometry(
            for: playerView.bounds,
            scale: scale,
            transitionReason: "test",
            animated: false
        )
        let inlineDrawable = CGSize(width: 390 * scale, height: 844 * scale)
        XCTAssertEqual(playerView.metalLayer.drawableSize, inlineDrawable)

        // What the window leaves behind: the layer is sized for the small
        // Picture in Picture drawable while the view is back at full size.
        playerView.metalLayer.drawableSize = CGSize(width: 320 * scale, height: 180 * scale)

        // A plain layout pass cannot see it, because the change test compares
        // against the last geometry applied rather than against the layer.
        playerView.updateMetalLayerGeometryIfNeeded()
        XCTAssertNotEqual(playerView.metalLayer.drawableSize, inlineDrawable)

        playerView.resynchronizeMetalLayerGeometry(reason: "pip-exit")

        XCTAssertEqual(playerView.metalLayer.drawableSize, inlineDrawable)
        XCTAssertEqual(playerView.metalLayer.frame, playerView.bounds)
    }

    @MainActor
    func testGeometryResyncWaitsForTheRestoredInlineLayout() {
        let scale = UIScreen.main.nativeScale
        let playerView = MPVPlayerView(frame: .zero)
        let pictureInPictureDrawable = CGSize(width: 320 * scale, height: 180 * scale)
        playerView.metalLayer.drawableSize = pictureInPictureDrawable

        // PiP delegate callbacks can restore the view before the inline
        // hierarchy has assigned its final size. Applying this zero size would
        // leave the small PiP drawable pinned at the top of the player.
        playerView.resynchronizeMetalLayerGeometry(reason: "pip-exit")

        XCTAssertEqual(playerView.metalLayer.drawableSize, pictureInPictureDrawable)
        XCTAssertEqual(
            playerView.pendingPictureInPictureGeometryResynchronizationReason,
            "pip-exit"
        )

        playerView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        playerView.layoutIfNeeded()

        XCTAssertEqual(
            playerView.metalLayer.drawableSize,
            CGSize(width: 390 * scale, height: 844 * scale)
        )
        XCTAssertNil(playerView.pendingPictureInPictureGeometryResynchronizationReason)
    }

    @MainActor
    func testGeometryResyncRetriesWhenInlineLayoutArrivesAfterPictureInPictureExit() async {
        let scale = UIScreen.main.nativeScale
        let playerView = MPVPlayerView(frame: .zero)
        let pictureInPictureDrawable = CGSize(width: 320 * scale, height: 180 * scale)
        playerView.metalLayer.drawableSize = pictureInPictureDrawable

        playerView.resynchronizeMetalLayerGeometry(reason: "pip-exit")
        XCTAssertNotNil(playerView.pictureInPictureGeometryResynchronizationTask)

        // This mirrors the delayed inline size that rotation previously forced
        // UIKit to apply manually after returning from PiP.
        playerView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(
            playerView.metalLayer.drawableSize,
            CGSize(width: 390 * scale, height: 844 * scale)
        )
        playerView.pictureInPictureGeometryResynchronizationTask?.cancel()
    }

    @MainActor
    func testPlacementReportsWhetherItMovedThePlayerView() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let playerView = MPVPlayerView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        container.addSubview(playerView)
        let pictureInPictureContainer = UIView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        let placement = try XCTUnwrap(MPVPictureInPictureViewPlacement(playerView: playerView))

        // Only a move that happened may re-size the renderer; the delegate
        // calls both directions more than once per lifecycle.
        XCTAssertFalse(placement.restorePlayer())
        XCTAssertTrue(placement.movePlayer(to: pictureInPictureContainer))
        XCTAssertFalse(placement.movePlayer(to: pictureInPictureContainer))
        XCTAssertTrue(placement.restorePlayer())
        XCTAssertTrue(placement.movePlayer(to: pictureInPictureContainer))
        XCTAssertTrue(placement.restorePlayer())
        XCTAssertFalse(placement.restorePlayer())
    }

    @MainActor
    func testPlacementRejectsAReentrantMoveDuringPictureInPictureLayout() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let playerView = MPVPlayerView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        let pictureInPictureContainer = ReentrantLayoutView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        container.addSubview(playerView)
        let placement = try XCTUnwrap(MPVPictureInPictureViewPlacement(playerView: playerView))
        var reentrantMoveResult: Bool?

        pictureInPictureContainer.onLayout = {
            reentrantMoveResult = placement.movePlayer(to: pictureInPictureContainer)
        }

        XCTAssertTrue(placement.movePlayer(to: pictureInPictureContainer))
        XCTAssertEqual(reentrantMoveResult, false)
        XCTAssertTrue(placement.isPlayerInPictureInPictureContainer)
    }

    /// Moving the view must not disturb the renderer: the Metal layer and the
    /// MPV output options travel with it, and Picture in Picture would lose
    /// Dolby Vision if they were rebuilt on the way.
    @MainActor
    func testPlacementKeepsTheRendererInvariant() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let playerView = MPVPlayerView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        container.addSubview(playerView)
        let placement = try XCTUnwrap(MPVPictureInPictureViewPlacement(playerView: playerView))
        let before = playerView.pictureInPictureRendererInvariantSnapshot()

        placement.movePlayer(to: UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180)))
        let hosted = playerView.pictureInPictureRendererInvariantSnapshot()
        placement.restorePlayer()
        let restored = playerView.pictureInPictureRendererInvariantSnapshot()

        XCTAssertEqual(before.metalLayerIdentifier, hosted.metalLayerIdentifier)
        XCTAssertEqual(before.metalPixelFormat, hosted.metalPixelFormat)
        XCTAssertEqual(before.metalColorSpaceName, hosted.metalColorSpaceName)
        XCTAssertEqual(
            before.usesExtendedDynamicRangeOutput,
            hosted.usesExtendedDynamicRangeOutput
        )
        XCTAssertEqual(before.selectedVideoOutputOptions, hosted.selectedVideoOutputOptions)
        XCTAssertEqual(before, restored)
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
        XCTAssertEqual(dolbyVisionOptions["target-colorspace-hint-mode"], "target")
        XCTAssertEqual(dolbyVisionOptions["hdr-compute-peak"], "yes")
        XCTAssertEqual(dolbyVisionOptions["hdr-peak-percentile"], "99.99")
        XCTAssertEqual(dolbyVisionOptions["hdr-peak-decay-rate"], "8")
        XCTAssertEqual(dolbyVisionOptions["hdr-scene-threshold-low"], "0.75")
        XCTAssertEqual(dolbyVisionOptions["hdr-scene-threshold-high"], "2.0")
        XCTAssertEqual(dolbyVisionOptions["hdr-contrast-recovery"], "0.20")
        XCTAssertEqual(dolbyVisionOptions["hdr-contrast-smoothness"], "6.5")
        XCTAssertNil(dolbyVisionOptions["gamma"])
        XCTAssertNil(dolbyVisionOptions["inverse-tone-mapping"])
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
            expectedHintMode: "target"
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
