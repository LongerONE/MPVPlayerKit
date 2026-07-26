import XCTest
import CoreMedia
import UIKit
import Metal
@testable import MPVPlayerKit

final class MPVPictureInPictureTests: XCTestCase {
    func testCapabilityProbeMergesRendererRecommendationsWithCandidateRequirements() {
        let recommendation = [
            "renderer.preference": "preserved",
            kCVPixelBufferWidthKey as String: 1,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ] as [String: Any]
        let required = MPVPictureInPictureCapabilityProbe.requiredPixelBufferAttributes(
            for: .rgba16Float,
            width: 640,
            height: 360
        )

        let attributes = MPVPictureInPictureCapabilityProbe.mergedPixelBufferAttributes(
            recommended: recommendation,
            required: required
        )

        XCTAssertEqual(attributes["renderer.preference"] as? String, "preserved")
        XCTAssertEqual(attributes[kCVPixelBufferWidthKey as String] as? Int, 640)
        XCTAssertEqual(attributes[kCVPixelBufferHeightKey as String] as? Int, 360)
        XCTAssertEqual(
            attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_64RGBAHalf
        )
        XCTAssertEqual(attributes[kCVPixelBufferMetalCompatibilityKey as String] as? Bool, true)
    }

    func testCapabilityProbeUsesBothX420MetalPlanes() {
        XCTAssertEqual(
            MPVPictureInPicturePixelBufferFormat.yuv42010VideoRange.metalTexturePlanes.map(\.label),
            ["Y", "UV"]
        )
        XCTAssertEqual(
            MPVPictureInPicturePixelBufferFormat.yuv42010VideoRange.metalTexturePlanes.map(\.pixelFormat),
            [.r16Unorm, .rg16Unorm]
        )
    }

    @available(iOS 17.0, *)
    @MainActor
    func testSampleBufferProbeUsesOpaqueAndFrameVaryingBGRAValues() {
        let first = MPVPictureInPictureSampleBufferProbe.testPixelComponents(frameIndex: 0)
        let next = MPVPictureInPictureSampleBufferProbe.testPixelComponents(frameIndex: 1)

        XCTAssertEqual(MPVPictureInPictureSampleBufferProbe.testAlpha, .max)
        XCTAssertEqual(first, [0, 0, 0])
        XCTAssertNotEqual(first, next)
        XCTAssertTrue(next.allSatisfy { $0 != 0 })
    }

    func testPictureInPictureFirstCaptureRequiresVideoOutputAndFrameSignal() {
        XCTAssertFalse(MPVPictureInPictureFrameCaptureReadiness.shouldCapture(
            hasValidVideoOutputParameters: false,
            hasPlaybackOrReconfigurationSignal: true,
            isPlaying: true,
            isWaitingForStart: true
        ))
        XCTAssertFalse(MPVPictureInPictureFrameCaptureReadiness.shouldCapture(
            hasValidVideoOutputParameters: true,
            hasPlaybackOrReconfigurationSignal: false,
            isPlaying: true,
            isWaitingForStart: true
        ))
        XCTAssertTrue(MPVPictureInPictureFrameCaptureReadiness.shouldCapture(
            hasValidVideoOutputParameters: true,
            hasPlaybackOrReconfigurationSignal: true,
            isPlaying: false,
            isWaitingForStart: true
        ))
    }

    func testPictureInPictureKeepsCapturingWhilePausedInAnActiveWindow() {
        // A paused Picture in Picture window still has to show the frame the
        // player seeked to, so captures continue while it is active.
        XCTAssertTrue(MPVPictureInPictureFrameCaptureReadiness.shouldCapture(
            hasValidVideoOutputParameters: true,
            hasPlaybackOrReconfigurationSignal: true,
            isPlaying: false,
            isWaitingForStart: false,
            isPictureInPictureActive: true
        ))
        XCTAssertFalse(MPVPictureInPictureFrameCaptureReadiness.shouldCapture(
            hasValidVideoOutputParameters: true,
            hasPlaybackOrReconfigurationSignal: true,
            isPlaying: false,
            isWaitingForStart: false,
            isPictureInPictureActive: false
        ))
    }

    func testCaptureCadenceFollowsTheVideoFrameRateWithinBounds() {
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.interval(
                videoFrameRate: 24,
                averageCaptureDuration: 0,
                isPlaying: true
            ),
            1.0 / 24,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.interval(
                videoFrameRate: 120,
                averageCaptureDuration: 0,
                isPlaying: true
            ),
            MPVPictureInPictureCaptureCadence.minimumPlayingInterval,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.interval(
                videoFrameRate: 0,
                averageCaptureDuration: 0,
                isPlaying: true
            ),
            1 / MPVPictureInPictureCaptureCadence.fallbackVideoFrameRate,
            accuracy: 0.0001
        )
    }

    func testCaptureCadenceBacksOffForExpensiveCapturesAndPausedPlayback() {
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.interval(
                videoFrameRate: 60,
                averageCaptureDuration: 0.06,
                isPlaying: true
            ),
            0.06 * MPVPictureInPictureCaptureCadence.captureCostFactor,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.interval(
                videoFrameRate: 60,
                averageCaptureDuration: 5,
                isPlaying: true
            ),
            MPVPictureInPictureCaptureCadence.maximumPlayingInterval,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.interval(
                videoFrameRate: 60,
                averageCaptureDuration: 0.01,
                isPlaying: false
            ),
            MPVPictureInPictureCaptureCadence.pausedInterval,
            accuracy: 0.0001
        )
    }

    func testPausedCaptureStopsOnceTheWindowShowsTheSeekedPosition() {
        // While paused MPV keeps returning the same frame, so captures only
        // continue until the captured position matches the player position.
        XCTAssertTrue(MPVPictureInPictureCaptureCadence.shouldSkipPausedCapture(
            isPlaying: false,
            isWaitingForStart: false,
            lastCapturedPresentationTime: 120,
            currentTime: 120.01
        ))
        XCTAssertFalse(MPVPictureInPictureCaptureCadence.shouldSkipPausedCapture(
            isPlaying: false,
            isWaitingForStart: false,
            lastCapturedPresentationTime: 120,
            currentTime: 135
        ))
        XCTAssertFalse(MPVPictureInPictureCaptureCadence.shouldSkipPausedCapture(
            isPlaying: false,
            isWaitingForStart: false,
            lastCapturedPresentationTime: nil,
            currentTime: 120
        ))
        XCTAssertFalse(MPVPictureInPictureCaptureCadence.shouldSkipPausedCapture(
            isPlaying: true,
            isWaitingForStart: false,
            lastCapturedPresentationTime: 120,
            currentTime: 120
        ))
        XCTAssertFalse(MPVPictureInPictureCaptureCadence.shouldSkipPausedCapture(
            isPlaying: false,
            isWaitingForStart: true,
            lastCapturedPresentationTime: 120,
            currentTime: 120
        ))
    }

    func testCaptureCadenceReschedulesOnlyForMeaningfulChanges() {
        XCTAssertTrue(MPVPictureInPictureCaptureCadence.shouldReschedule(
            currentInterval: nil,
            nextInterval: 0.04
        ))
        XCTAssertFalse(MPVPictureInPictureCaptureCadence.shouldReschedule(
            currentInterval: 0.04,
            nextInterval: 0.042
        ))
        XCTAssertTrue(MPVPictureInPictureCaptureCadence.shouldReschedule(
            currentInterval: 0.04,
            nextInterval: 0.5
        ))
    }

    func testCaptureDurationAverageIgnoresUnusableSamples() {
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.averageCaptureDuration(
                previousAverage: 0,
                sample: 0.02
            ),
            0.02,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.averageCaptureDuration(
                previousAverage: 0.02,
                sample: -1
            ),
            0.02,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.averageCaptureDuration(
                previousAverage: 0.02,
                sample: 0.06
            ),
            0.03,
            accuracy: 0.0001
        )
    }

    func testCaptureDurationAverageRejectsOneOffPipelineCompilation() {
        // The first frame after a playback restart can cost seconds while MPV
        // compiles its render pipeline. Holding that in the average would pin
        // the cadence at its slowest.
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.averageCaptureDuration(
                previousAverage: 0,
                sample: 1.685
            ),
            MPVPictureInPictureCaptureCadence.captureDurationOutlierFloor,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.averageCaptureDuration(
                previousAverage: 0.07,
                sample: 1.685
            ),
            0.07,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MPVPictureInPictureCaptureCadence.averageCaptureDuration(
                previousAverage: 0.2,
                sample: 0.4
            ),
            0.25,
            accuracy: 0.0001
        )
    }

    func testSubtitleOverlayStyleReadsMPVPropertyValues() {
        let style = MPVPictureInPictureSubtitleStyle(propertyValues: [
            MPVProperty.subtitleFontSize: "44.000",
            MPVProperty.subtitleBold: "yes",
            MPVProperty.subtitleColor: "#FFEEDDCC",
            MPVProperty.subtitleOutlineSize: "1.500",
            MPVProperty.subtitleMarginY: "50",
        ])

        XCTAssertEqual(style.fontSize, 44)
        XCTAssertTrue(style.bold)
        XCTAssertEqual(style.textColor, "#FFEEDDCC")
        XCTAssertEqual(style.outlineSize, 1.5)
        XCTAssertEqual(style.marginY, 50)
        XCTAssertEqual(style.shadowOffset, 0)
    }

    func testSubtitleOverlayLayoutScalesWithFrameHeight() {
        var style = MPVPictureInPictureSubtitleStyle()
        style.fontSize = 36
        style.marginY = 36
        style.outlineSize = 2

        let layout = MPVPictureInPictureSubtitleLayout(
            style: style,
            frameWidth: 1280,
            frameHeight: 720
        )
        XCTAssertEqual(layout.pointSize, 36, accuracy: 0.001)
        XCTAssertEqual(layout.bottomMargin, 36, accuracy: 0.001)
        XCTAssertEqual(layout.outlineWidth, 2, accuracy: 0.001)

        let smallLayout = MPVPictureInPictureSubtitleLayout(
            style: style,
            frameWidth: 640,
            frameHeight: 360
        )
        XCTAssertEqual(smallLayout.pointSize, 18, accuracy: 0.001)
        XCTAssertEqual(smallLayout.bottomMargin, 18, accuracy: 0.001)
        XCTAssertEqual(smallLayout.maximumWidth, 640 * 0.92, accuracy: 0.001)
    }

    func testSubtitleOverlayParsesMPVColors() {
        let opaqueWhite = MPVPictureInPictureSubtitleOverlay.color("#FFFFFFFF")
        XCTAssertEqual(opaqueWhite?.alpha, 1)
        XCTAssertEqual(MPVPictureInPictureSubtitleOverlay.color("#00000000")?.alpha, 0)
        XCTAssertEqual(MPVPictureInPictureSubtitleOverlay.color("#FFFFFF")?.alpha, 1)
        XCTAssertNil(MPVPictureInPictureSubtitleOverlay.color("white"))
    }

    func testSubtitleOverlayNormalizesCapturedText() {
        XCTAssertEqual(
            MPVPictureInPictureSubtitleOverlay.normalizedText(" line one\r\nline two \n"),
            "line one\nline two"
        )
        XCTAssertEqual(MPVPictureInPictureSubtitleOverlay.normalizedText("  \n "), "")
    }

    func testRenderBudgetBoundsCapturesBeforeAVKitReportsAWindowSize() {
        // A 4K screenshot converted at full resolution costs about ten times
        // the work the window can show, and delays the first frame AVKit waits
        // for before starting Picture in Picture.
        let budget = MPVPictureInPictureRenderBudget.resolve(
            reportedRenderSize: CMVideoDimensions(width: 0, height: 0)
        )
        XCTAssertEqual(budget.width, MPVPictureInPictureRenderBudget.maximumWidth)
        XCTAssertEqual(budget.height, MPVPictureInPictureRenderBudget.maximumHeight)

        let reported = MPVPictureInPictureRenderBudget.resolve(
            reportedRenderSize: CMVideoDimensions(width: 370, height: 208),
            screenScale: 3
        )
        XCTAssertEqual(reported.width, 1110)
        XCTAssertEqual(reported.height, 624)
    }

    func testRenderBudgetKeepsWindowSizesAtNativePixelsWithinTheCeiling() {
        // AVKit reports points. A 3x screen needs three times the pixels, up to
        // the budget, or the window is softer than the inline player.
        let capped = MPVPictureInPictureRenderBudget.resolve(
            reportedRenderSize: CMVideoDimensions(width: 640, height: 360),
            screenScale: 3
        )
        XCTAssertEqual(capped.width, MPVPictureInPictureRenderBudget.maximumWidth)
        XCTAssertEqual(capped.height, MPVPictureInPictureRenderBudget.maximumHeight)
    }

    func testRenderBudgetIgnoresWindowSizeJitterDuringTheOpeningAnimation() {
        let settled = CMVideoDimensions(width: 393, height: 221)
        XCTAssertFalse(MPVPictureInPictureRenderBudget.isSignificantChange(
            from: settled,
            to: CMVideoDimensions(width: 392, height: 220)
        ))
        XCTAssertTrue(MPVPictureInPictureRenderBudget.isSignificantChange(
            from: settled,
            to: CMVideoDimensions(width: 200, height: 112)
        ))
        XCTAssertTrue(MPVPictureInPictureRenderBudget.isSignificantChange(
            from: CMVideoDimensions(width: 0, height: 0),
            to: settled
        ))
        XCTAssertFalse(MPVPictureInPictureRenderBudget.isSignificantChange(
            from: settled,
            to: CMVideoDimensions(width: 0, height: 0)
        ))
    }

    func testPictureInPictureSampleDurationFollowsTheVideoFrameRate() {
        XCTAssertEqual(
            MPVPictureInPictureFrameConverter.sampleDuration(videoFrameRate: 30),
            CMTime(value: 1, timescale: 30)
        )
        XCTAssertEqual(
            MPVPictureInPictureFrameConverter.sampleDuration(videoFrameRate: 0),
            CMTime(value: 1, timescale: 25)
        )
    }

    func testPictureInPictureFirstCaptureDoesNotRequireFiniteDuration() {
        // Live streams commonly report an unknown duration. Readiness is
        // based solely on MPV video-output parameters and frame signals.
        XCTAssertTrue(MPVPictureInPictureFrameCaptureReadiness.shouldCapture(
            hasValidVideoOutputParameters: true,
            hasPlaybackOrReconfigurationSignal: true,
            isPlaying: true,
            isWaitingForStart: false
        ))
    }

    func testInlineCoverLifecycleTransitionsFromWillStartToDidStart() {
        var lifecycle = MPVPictureInPictureInlineCoverLifecycle()

        XCTAssertEqual(lifecycle.state, .hidden)
        lifecycle.requestStart()
        XCTAssertEqual(lifecycle.state, .starting)
        XCTAssertTrue(lifecycle.didStart())
        XCTAssertEqual(lifecycle.state, .visible)
    }

    func testInlineCoverLifecycleIgnoresUnexpectedOrDuplicateDidStart() {
        var lifecycle = MPVPictureInPictureInlineCoverLifecycle()

        XCTAssertFalse(lifecycle.didStart())
        XCTAssertEqual(lifecycle.state, .hidden)

        lifecycle.requestStart()
        XCTAssertTrue(lifecycle.didStart())
        XCTAssertFalse(lifecycle.didStart())
        XCTAssertEqual(lifecycle.state, .visible)
    }

    func testInlineCoverLifecycleClearsForFailureStopAndTeardown() {
        var lifecycle = MPVPictureInPictureInlineCoverLifecycle()

        lifecycle.requestStart()
        XCTAssertFalse(lifecycle.end())
        XCTAssertEqual(lifecycle.state, .hidden)

        lifecycle.requestStart()
        _ = lifecycle.didStart()
        XCTAssertTrue(lifecycle.end())
        XCTAssertEqual(lifecycle.state, .hidden)
        XCTAssertFalse(lifecycle.end())
    }

    @MainActor
    func testInlineCoverAttachesToAndDetachesFromPlayerView() {
        let playerView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let cover = MPVPictureInPictureInlineCover()

        cover.show(over: playerView)
        let attachedCover = playerView.subviews.first {
            $0.accessibilityIdentifier == "MPVPlayerView.pictureInPictureInlineCover"
        }
        XCTAssertNotNil(attachedCover)
        XCTAssertTrue(attachedCover?.superview === playerView)

        cover.hide()
        XCTAssertNil(attachedCover?.superview)
        XCTAssertFalse(playerView.subviews.contains { $0 === attachedCover })
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

    func testPlayerTeardownNeverRestartsPictureInPictureFrameUpdates() {
        XCTAssertFalse(MPVPictureInPictureTeardownPolicy.shouldStartFrameUpdates(
            isTearingDown: true
        ))
        XCTAssertFalse(
            MPVPictureInPictureTeardownPolicy.shouldResumeAutomaticReadinessUpdates(
                allowsAutomaticStartFromInline: true,
                isTearingDown: true
            )
        )
        XCTAssertFalse(MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
            isStartCancellationRequested: false,
            isTearingDown: true
        ))
    }

    func testPictureInPictureFrameUpdatesCanResumeForANewLifecycle() {
        XCTAssertTrue(MPVPictureInPictureTeardownPolicy.shouldStartFrameUpdates(
            isTearingDown: false
        ))
        XCTAssertTrue(
            MPVPictureInPictureTeardownPolicy.shouldResumeAutomaticReadinessUpdates(
                allowsAutomaticStartFromInline: true,
                isTearingDown: false
            )
        )
        XCTAssertTrue(MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
            isStartCancellationRequested: false,
            isTearingDown: false
        ))
    }

    func testPictureInPictureUsesCompatibleRawScreenshotArguments() {
        XCTAssertEqual(
            MPVPlayerView.pictureInPictureScreenshotArgumentCandidates(
                for: .videoWithSubtitleOverlay
            ),
            [["video", "bgra"], ["video"]]
        )
        XCTAssertEqual(
            MPVPlayerView.pictureInPictureScreenshotArgumentCandidates(for: .window),
            [["window", "bgra"], ["window"]]
        )
    }

    @MainActor
    func testPictureInPictureCapturesVideoFramesByDefault() {
        let playerView = MPVPlayerView(frame: .zero)

        XCTAssertEqual(playerView.pictureInPictureCaptureMode, .videoWithSubtitleOverlay)
        XCTAssertTrue(playerView.drawsSubtitlesInPictureInPicture)

        playerView.pictureInPictureCaptureModeRawValue =
            MPVPictureInPictureCaptureMode.window.rawValue
        XCTAssertEqual(playerView.pictureInPictureCaptureMode, .window)

        playerView.pictureInPictureCaptureModeRawValue = 99
        XCTAssertEqual(playerView.pictureInPictureCaptureMode, .videoWithSubtitleOverlay)
    }

    func testWindowCropUsesTheVideoAreaMPVReports() {
        // A portrait window with the video letterboxed in the middle, as MPV
        // reported on an iPhone 15 Pro: video display (0, 946) 1179x663.
        XCTAssertEqual(
            MPVPictureInPictureVideoRect.resolve(
                frameWidth: 1179,
                frameHeight: 2556,
                left: 0,
                top: 946,
                right: 0,
                bottom: 947,
                displayWidth: 3840,
                displayHeight: 2160
            ),
            MPVPictureInPictureCropRect(x: 0, y: 946, width: 1179, height: 663)
        )
    }

    func testWindowCropUsesTheDisplayAspectWhenMarginsAreUnavailable() {
        // Unreadable margins would otherwise leave the black bars in the frame
        // and give the window the shape of the drawable.
        let crop = MPVPictureInPictureVideoRect.resolve(
            frameWidth: 1179,
            frameHeight: 2556,
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
            displayWidth: 3840,
            displayHeight: 2160
        )

        XCTAssertEqual(crop.width, 1179)
        XCTAssertEqual(crop.height, 663)
        XCTAssertEqual(crop.x, 0)
        XCTAssertEqual(crop.y, 946)
    }

    func testWindowCropKeepsTheWholeFrameWithoutADisplayAspect() {
        XCTAssertEqual(
            MPVPictureInPictureVideoRect.resolve(
                frameWidth: 1179,
                frameHeight: 2556,
                left: 0,
                top: 0,
                right: 0,
                bottom: 0,
                displayWidth: 0,
                displayHeight: 0
            ),
            MPVPictureInPictureCropRect(x: 0, y: 0, width: 1179, height: 2556)
        )
        XCTAssertEqual(
            MPVPictureInPictureVideoRect.resolve(
                frameWidth: 1179,
                frameHeight: 2556,
                left: 700,
                top: 0,
                right: 700,
                bottom: 0,
                displayWidth: 0,
                displayHeight: 0
            ),
            MPVPictureInPictureCropRect(x: 0, y: 0, width: 1179, height: 2556)
        )
    }

    func testOutputSizeKeepsTheDisplayAspectOfAnamorphicVideo() {
        // Stored 1920x1080 shown at 2538x1080: the frame has to carry the
        // display aspect, or the Picture in Picture window is the wrong shape.
        let size = MPVPictureInPictureOutputSize.resolve(
            cropWidth: 1920,
            cropHeight: 1080,
            displayWidth: 2538,
            displayHeight: 1080,
            renderSize: CMVideoDimensions(width: 1280, height: 720)
        )

        XCTAssertEqual(
            Double(size.width) / Double(size.height),
            2538.0 / 1080.0,
            accuracy: 0.01
        )
        XCTAssertLessThanOrEqual(size.width, 1280)
        XCTAssertLessThanOrEqual(size.height, 720)
    }

    func testOutputSizeFitsSquarePixelVideoInTheRenderBudget() {
        let size = MPVPictureInPictureOutputSize.resolve(
            cropWidth: 3840,
            cropHeight: 2160,
            displayWidth: 3840,
            displayHeight: 2160,
            renderSize: CMVideoDimensions(width: 1280, height: 720)
        )

        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 720)
    }

    func testOutputSizeFallsBackToTheCropAspectAndNeverUpscales() {
        let unknownDisplay = MPVPictureInPictureOutputSize.resolve(
            cropWidth: 1179,
            cropHeight: 663,
            displayWidth: 0,
            displayHeight: 0,
            renderSize: CMVideoDimensions(width: 1280, height: 720)
        )
        XCTAssertEqual(unknownDisplay.width, 1179)
        XCTAssertEqual(unknownDisplay.height, 663)

        let smallSource = MPVPictureInPictureOutputSize.resolve(
            cropWidth: 640,
            cropHeight: 360,
            displayWidth: 640,
            displayHeight: 360,
            renderSize: CMVideoDimensions(width: 1280, height: 720)
        )
        XCTAssertEqual(smallSource.width, 640)
        XCTAssertEqual(smallSource.height, 360)
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
