import CoreFoundation
import CoreMedia
import XCTest
import UIKit
@testable import MPVPlayerKit

private struct TestUnsafeTransfer<Value>: @unchecked Sendable {
    let value: Value
}

final class MPVPlayerModelTests: XCTestCase {
    func testSourceFilesStayWithinMaintenanceLineLimit() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesURL = packageRoot.appendingPathComponent("Sources/MPVPlayerKit")
        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: sourcesURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        XCTAssertFalse(sourceFiles.isEmpty)
        for sourceFile in sourceFiles {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
            XCTAssertLessThanOrEqual(
                lineCount,
                600,
                "\(sourceFile.lastPathComponent) has \(lineCount) lines"
            )
        }
    }

    func testMPVSetupReappliesSubtitleStyleAfterInitialization() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let setupSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MPVPlayerKit/MPVPlayerView+Setup.swift"),
            encoding: .utf8
        )
        let initializeRange = try XCTUnwrap(setupSource.range(of: "mpv_initialize(mpv)"))
        let runtimeStyleRange = try XCTUnwrap(setupSource.range(of: "applyUserSubtitleStyleProperties()"))

        XCTAssertLessThan(initializeRange.lowerBound, runtimeStyleRange.lowerBound)
    }

    func testConfigurationCreatesBridgeValues() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let configuration = MPVPlayerConfiguration(
            url: url,
            headers: ["Authorization": "Bearer token"],
            userAgent: "Tests/1.0",
            forceSoftwareDecode: true,
            isDolbyVisionPlayback: true,
            videoQuality: .highQuality,
            debandEnabled: true,
            smoothPlaybackEnabled: true
        )

        let values = configuration.bridgeDictionary

        XCTAssertEqual(values["url"] as? String, url.absoluteString)
        XCTAssertEqual(values["headers"] as? [String: String], ["Authorization": "Bearer token"])
        XCTAssertEqual(values["userAgent"] as? String, "Tests/1.0")
        XCTAssertEqual((values["forceSoftwareDecode"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values["isDolbyVisionPlayback"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values["videoQuality"] as? NSNumber)?.intValue, MPVVideoQuality.highQuality.rawValue)
        XCTAssertEqual((values["debandEnabled"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values["smoothPlaybackEnabled"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values["interpolationQuality"] as? NSNumber)?.intValue, MPVInterpolationQuality.standard.rawValue)
        XCTAssertEqual(values["temporalScaler"] as? String, MPVTemporalScaler.oversample.rawValue)
        XCTAssertEqual((values["interpolationThreshold"] as? NSNumber)?.doubleValue, 0.01)
        XCTAssertEqual((values["tscaleClamp"] as? NSNumber)?.doubleValue, 1.0)
        XCTAssertEqual((values["tscaleAntiring"] as? NSNumber)?.doubleValue, 0.0)
    }

    func testHighQualityInterpolationPresetAndAdvancedValues() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let options = MPVInterpolationOptions(
            quality: .highQuality,
            threshold: -1,
            blur: 0.8,
            clamp: 0.75,
            radius: 4,
            antiring: 0.7
        )
        let values = MPVPlayerConfiguration(
            url: url,
            interpolationOptions: options
        ).bridgeDictionary

        XCTAssertEqual(values["temporalScaler"] as? String, "mitchell")
        XCTAssertEqual((values["interpolationThreshold"] as? NSNumber)?.doubleValue, -1)
        XCTAssertEqual((values["tscaleBlur"] as? NSNumber)?.doubleValue, 0.8)
        XCTAssertEqual((values["tscaleClamp"] as? NSNumber)?.doubleValue, 0.75)
        XCTAssertEqual((values["tscaleRadius"] as? NSNumber)?.doubleValue, 4)
        XCTAssertEqual((values["tscaleAntiring"] as? NSNumber)?.doubleValue, 0.7)
    }

    func testInterpolationOptionsClampInvalidAdvancedValues() {
        let options = MPVInterpolationOptions(
            quality: .smooth,
            threshold: 5,
            blur: 0.1,
            clamp: -2,
            radius: 100,
            antiring: 4
        )

        XCTAssertEqual(options.temporalScaler, .linear)
        XCTAssertEqual(options.threshold, 1)
        XCTAssertEqual(options.blur, 0.5)
        XCTAssertEqual(options.clamp, 0)
        XCTAssertEqual(options.radius, 16)
        XCTAssertEqual(options.antiring, 1)
    }

    func testMediaTrackParsesBridgeDictionary() throws {
        let track = try XCTUnwrap(MPVMediaTrack(dictionary: [
            "trackID": NSNumber(value: 7),
            "mpvType": "audio",
            "name": "English · AAC",
            "languageCode": "eng",
            "codec": "aac",
            "bitRate": NSNumber(value: 256_000),
            "isEnabled": NSNumber(value: true),
            "isImageSubtitle": NSNumber(value: false),
        ] as NSDictionary))

        XCTAssertEqual(track.id, 7)
        XCTAssertEqual(track.type, .audio)
        XCTAssertEqual(track.name, "English · AAC")
        XCTAssertEqual(track.languageCode, "eng")
        XCTAssertEqual(track.codec, "aac")
        XCTAssertEqual(track.bitRate, 256_000)
        XCTAssertTrue(track.isSelected)
        XCTAssertFalse(track.isImageSubtitle)
    }

    func testMediaTrackRejectsUnknownTrackType() {
        let track = MPVMediaTrack(dictionary: [
            "trackID": NSNumber(value: 1),
            "mpvType": "unknown",
        ] as NSDictionary)

        XCTAssertNil(track)
    }

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

    func testQuickPlayerOnlyShowsLoadingIndicatorWhileBuffering() {
        XCTAssertTrue(MPVQuickPlayerViewController.shouldShowLoading(for: .buffering))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .readyToPlay))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .bufferFinished))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .paused))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .playedToTheEnd))
        XCTAssertFalse(MPVQuickPlayerViewController.shouldShowLoading(for: .error))
    }

    func testQuickPlayerExposesConfigurationAndRuntimeSettings() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let controller = MPVQuickPlayerViewController(
            configuration: MPVPlayerConfiguration(
                url: url,
                videoQuality: .highQuality,
                debandEnabled: true,
                interpolationOptions: .smooth
            ),
            autoplay: false
        )

        XCTAssertEqual(controller.videoQuality, .highQuality)
        XCTAssertTrue(controller.debandEnabled)
        XCTAssertEqual(controller.interpolationOptions, .smooth)
        XCTAssertTrue(controller.prefersStatusBarHidden)
        XCTAssertEqual(controller.preferredStatusBarUpdateAnimation, .fade)
        XCTAssertTrue(controller.modalPresentationCapturesStatusBarAppearance)

        controller.setPlaybackRate(1.5)
        controller.setVideoQuality(.powerSaving)
        controller.setDebandEnabled(false)
        controller.setInterpolationOptions(.highQuality)
        controller.setSubtitleDelay(90)
        controller.setSubtitleStyle(.highContrast)

        XCTAssertEqual(controller.playbackRate, 1.5)
        XCTAssertEqual(controller.videoQuality, .powerSaving)
        XCTAssertFalse(controller.debandEnabled)
        XCTAssertEqual(controller.interpolationOptions, .highQuality)
        XCTAssertEqual(controller.subtitleDelay, 60)
        XCTAssertEqual(controller.subtitleStyle, .highContrast)
    }

    func testQuickPlayerCanForceLandscapeWhenHostOnlySupportsPortrait() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let controller = MPVQuickPlayerViewController(
            url: url,
            autoplay: false,
            forceLandscape: true
        )

        XCTAssertTrue(controller.isLandscapeForced)
        XCTAssertFalse(MPVQuickPlayerViewController.supportsLandscape(orientationNames: [
            "UIInterfaceOrientationPortrait",
        ]))
        XCTAssertTrue(MPVQuickPlayerViewController.supportsLandscape(orientationNames: [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeRight",
        ]))

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
        let contentTranslation = CGPoint(
            x: contentEnd.x - contentStart.x,
            y: contentEnd.y - contentStart.y
        )
        XCTAssertGreaterThan(abs(contentTranslation.x), abs(contentTranslation.y))

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
    func testQuickPlayerExposesPictureInPictureControl() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let controller = MPVQuickPlayerViewController(url: url, autoplay: false)
        controller.loadViewIfNeeded()

        XCTAssertTrue(
            controller.trackButtonStack.arrangedSubviews.contains(
                controller.pictureInPictureButton
            )
        )
        XCTAssertEqual(
            controller.pictureInPictureButton.accessibilityIdentifier,
            "MPVQuickPlayer.pictureInPictureButton"
        )
        XCTAssertEqual(
            controller.pictureInPictureButton.isEnabled,
            controller.player.isPictureInPictureSupported
        )
        if controller.player.isPictureInPictureSupported {
            XCTAssertTrue(
                controller.preparePictureInPicturePlayback(
                    activateAudioSession: {}
                )
            )
            XCTAssertTrue(
                controller.player.allowsAutomaticPictureInPictureFromInline
            )
        }
    }

    @MainActor
    func testPictureInPictureUsesWindowSizedMetalDrawable() {
        let playerView = MPVPlayerView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        let pictureInPictureLayer = CALayer()
        let pictureInPictureBounds = CGRect(x: 0, y: 0, width: 320, height: 180)

        playerView.displayMetalLayerForPictureInPicture(
            in: pictureInPictureLayer,
            bounds: pictureInPictureBounds,
            scale: 2
        )

        XCTAssertTrue(playerView.metalLayer.superlayer === pictureInPictureLayer)
        XCTAssertEqual(playerView.metalLayer.frame, pictureInPictureBounds)
        XCTAssertEqual(playerView.metalLayer.drawableSize, CGSize(width: 640, height: 360))
        XCTAssertEqual(playerView.pictureInPicturePreferredContentSize, CGSize(width: 16, height: 9))

        playerView.restoreMetalLayerAfterPictureInPicture()

        XCTAssertTrue(playerView.metalLayer.superlayer === playerView.layer)
        XCTAssertEqual(playerView.metalLayer.frame.size, playerView.bounds.size)
    }

    @MainActor
    func testPictureInPictureCoversInlinePlaybackUntilItStops() {
        let playerView = MPVPlayerView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 219)
        )

        playerView.setInlinePlaybackCoveredForPictureInPicture(true)

        XCTAssertTrue(
            playerView.pictureInPictureInlineCoverLayer.superlayer === playerView.layer
        )
        XCTAssertEqual(
            playerView.pictureInPictureInlineCoverLayer.frame,
            playerView.bounds
        )

        playerView.setInlinePlaybackCoveredForPictureInPicture(false)

        XCTAssertNil(playerView.pictureInPictureInlineCoverLayer.superlayer)
    }

    func testPictureInPictureSkipClampsToPlayableRange() {
        XCTAssertEqual(
            MPVPictureInPicturePlaybackMath.fixedSkipInterval(
                requestedInterval: -10
            ),
            -15
        )
        XCTAssertEqual(
            MPVPictureInPicturePlaybackMath.fixedSkipInterval(
                requestedInterval: 10
            ),
            15
        )
        XCTAssertEqual(
            MPVPictureInPicturePlaybackMath.clampedSeekTime(
                currentTime: 10,
                duration: 100,
                interval: -15
            ),
            0
        )
        XCTAssertEqual(
            MPVPictureInPicturePlaybackMath.clampedSeekTime(
                currentTime: 95,
                duration: 100,
                interval: 15
            ),
            100
        )
        XCTAssertEqual(
            MPVPictureInPicturePlaybackMath.clampedSeekTime(
                currentTime: 40,
                duration: 100,
                interval: 15
            ),
            55
        )
    }

    func testPictureInPictureReportsFinitePlaybackRange() {
        let range = MPVPictureInPicturePlaybackMath.timeRange(duration: 125.5)

        XCTAssertEqual(range.start.seconds, 0)
        XCTAssertEqual(range.duration.seconds, 125.5, accuracy: 0.001)
        XCTAssertFalse(MPVPictureInPicturePlaybackMath.timeRange(duration: 0).isValid)
    }

    func testPictureInPictureFrameBuildsDisplayableSampleBuffer() throws {
        let frame = MPVPictureInPictureFrame(
            width: 2,
            height: 1,
            stride: 8,
            pixels: Data([0, 0, 255, 255, 0, 255, 0, 255]),
            presentationTime: 12.5,
            subtitleText: nil
        )

        let sampleBuffer = try XCTUnwrap(frame.makeSampleBuffer())

        XCTAssertEqual(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
            12.5,
            accuracy: 0.001
        )
        XCTAssertNotNil(CMSampleBufferGetImageBuffer(sampleBuffer))
    }

    func testPictureInPictureFrameCompositesSubtitleWithoutGPUOutput() throws {
        let width = 320
        let height = 180
        let frame = MPVPictureInPictureFrame(
            width: width,
            height: height,
            stride: width * 4,
            pixels: Data(repeating: 0, count: width * height * 4),
            presentationTime: 0,
            subtitleText: "Picture in Picture subtitle"
        )

        let sampleBuffer = try XCTUnwrap(frame.makeSampleBuffer())
        let pixelBuffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sampleBuffer))
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * height
        let bytes = UnsafeRawBufferPointer(
            start: CVPixelBufferGetBaseAddress(pixelBuffer),
            count: byteCount
        )

        XCTAssertTrue(bytes.enumerated().contains { offset, byte in
            offset % 4 != 3 && byte != 0
        })
    }

    func testPictureInPictureScreenshotAvoidsGPUCompositedOutput() {
        XCTAssertEqual(
            MPVPlayerView.pictureInPictureScreenshotArgumentCandidates,
            [
                ["video", "bgra"],
                ["video"],
            ]
        )
    }

    func testSubtitleStyleClampsNumericValuesAndBuildsBridgeDictionary() {
        let style = MPVSubtitleStyle(
            fontSize: 200,
            bold: true,
            outlineSize: -1,
            shadowOffset: 20,
            bottomOffset: -20
        )

        XCTAssertEqual(style.fontSize, 120)
        XCTAssertTrue(style.bold)
        XCTAssertEqual(style.outlineSize, 0)
        XCTAssertEqual(style.shadowOffset, 10)
        XCTAssertEqual(style.bottomOffset, 0)
        XCTAssertEqual((style.bridgeDictionary["fontSize"] as? NSNumber)?.doubleValue, 120)
        XCTAssertEqual((style.bridgeDictionary["bold"] as? NSNumber)?.boolValue, true)
    }

    func testSubtitleDocumentDecodesUTF8SRTAndCleansASSOverrides() throws {
        let source = """
        1
        00:00:05,000 --> 00:00:08,000
        {\\an8\\pos(960,100)}English

        2
        00:00:05,000 --> 00:00:08,000
        {\\an2\\pos(960,980)}中文字幕
        """
        let document = try MPVSubtitleDocument.decode(
            Data(source.utf8),
            sourceURL: URL(fileURLWithPath: "/tmp/test.srt")
        )

        XCTAssertEqual(document.format, .subRip)
        XCTAssertEqual(document.cues.count, 1)
        XCTAssertEqual(document.cues[0].text, "English\n中文字幕")
        XCTAssertEqual(document.cues(at: 6).map(\.text), ["English\n中文字幕"])
        XCTAssertTrue(document.cues(at: 9).isEmpty)
    }

    func testSubtitleDocumentDecodesGB18030SRT() throws {
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))
        )
        let source = "1\n00:00:00,000 --> 00:00:02,000\n中文字幕\n"
        let data = try XCTUnwrap(source.data(using: encoding))
        let document = try MPVSubtitleDocument.decode(
            data,
            sourceURL: URL(fileURLWithPath: "/tmp/test.srt")
        )

        XCTAssertEqual(document.cues.first?.text, "中文字幕")
    }

    @MainActor
    func testPlayerViewExposesReplaceableClientSubtitleRenderer() {
        final class Renderer: MPVSubtitleRenderer {
            let view = UIView()
            var presentations: [MPVSubtitlePresentation] = []

            func render(_ presentation: MPVSubtitlePresentation) {
                presentations.append(presentation)
            }

            func clear() {
                presentations.append(MPVSubtitlePresentation(cues: [], style: .defaultStyle))
            }
        }

        let renderer = Renderer()
        let playerView = MPVPlayerView(frame: .zero)
        playerView.useClientSubtitleRenderer(renderer)
        playerView.selectClientSubtitle(MPVSubtitleDocument(
            format: .subRip,
            cues: [MPVSubtitleCue(startTime: 1, endTime: 3, text: "Hello")]
        ))
        playerView.updateClientSubtitle(at: 2)

        XCTAssertTrue(playerView.clientSubtitleRenderer === renderer)
        XCTAssertEqual(renderer.presentations.last?.cues.first?.text, "Hello")
        XCTAssertTrue(renderer.view.superview === playerView)
    }

    func testQuickPlayerUsesAvailableSFSymbolControls() {
        [
            "xmark",
            "play.fill",
            "pause.fill",
            "film",
            "waveform",
            "captions.bubble",
            "gearshape",
            "rectangle.landscape.rotate",
            "sun.max.fill",
            "speaker.wave.2.fill",
        ].forEach { symbol in
            XCTAssertNotNil(UIImage(systemName: symbol), symbol)
        }
    }

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
            MPVQuickPlayerViewController.interpolationTitle(.highQuality, localization: "en"),
            "High Quality"
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

    func testLocalizationUsesSimplifiedChineseOnlyForSimplifiedChineseLocales() {
        ["zh-Hans", "zh-Hans-CN", "zh_CN", "zh-SG"].forEach { language in
            XCTAssertEqual(
                MPVLocalization.localizationIdentifier(preferredLanguages: [language]),
                "zh-Hans",
                language
            )
        }
        ["zh-Hant", "zh-TW", "zh-HK", "zh", "en", "ja", "fr"].forEach { language in
            XCTAssertEqual(
                MPVLocalization.localizationIdentifier(preferredLanguages: [language]),
                "en",
                language
            )
        }
        XCTAssertEqual(
            MPVLocalization.localizationIdentifier(preferredLanguages: []),
            "en"
        )
    }

    func testLocalizationLoadsPackageResourcesAndFallsBackToEnglish() {
        XCTAssertEqual(
            MPVLocalization.string("settings.title", localization: "zh-Hans"),
            "播放设置"
        )
        XCTAssertEqual(
            MPVLocalization.string("settings.title", localization: "zh-Hant"),
            "Playback Settings"
        )
        XCTAssertEqual(
            MPVLocalization.string(
                "status.buffering",
                localization: "zh-Hans",
                arguments: [42]
            ),
            "正在缓冲 42%"
        )
    }

    @MainActor
    func testDiagnosticsCanRunOnMPVQueue() async {
        let playerView = MPVPlayerView(frame: .zero)
        let transfer = TestUnsafeTransfer(value: playerView)

        let shouldPrint = await withCheckedContinuation { continuation in
            playerView.queue.async {
                transfer.value.logSubtitleTextChange()
                let shouldPrint = transfer.value.shouldPrintMPVLogMessage(
                    prefix: "subtitle",
                    level: "info",
                    text: "glyph rendered"
                )
                continuation.resume(returning: shouldPrint)
            }
        }
        XCTAssertTrue(shouldPrint)
    }

    @MainActor
    func testSubtitleSourceAndArgumentsCanBePreparedOnMPVQueue() async {
        let playerView = MPVPlayerView(frame: .zero)
        let transfer = TestUnsafeTransfer(value: playerView)

        let result = await withCheckedContinuation { continuation in
            playerView.queue.async {
                let remoteSource = transfer.value.normalizedMPVSource(
                    "https://example.com/Stream.srt?token=value"
                )
                let localSource = transfer.value.normalizedMPVSource(
                    "file:///tmp/External%20Subtitle.srt"
                )
                let cargs = transfer.value.makeOwnedCArgs("sub-add", [remoteSource, "auto"])
                var arguments: [String?] = []
                for pointer in cargs {
                    if let pointer {
                        arguments.append(String(cString: pointer))
                    } else {
                        arguments.append(nil)
                    }
                }
                for pointer in cargs where pointer != nil {
                    free(UnsafeMutablePointer(mutating: pointer!))
                }
                continuation.resume(returning: (remoteSource, localSource, arguments))
            }
        }

        XCTAssertEqual(result.0, "https://example.com/Stream.srt?token=value")
        XCTAssertEqual(result.1, "/tmp/External Subtitle.srt")
        XCTAssertEqual(result.2, ["sub-add", result.0, "auto", nil])
    }

    @MainActor
    func testRuntimeVideoOptionHelpersCanRunOnMPVQueue() async {
        let playerView = MPVPlayerView(frame: .zero)
        let transfer = TestUnsafeTransfer(value: playerView)

        await withCheckedContinuation { continuation in
            playerView.queue.async {
                transfer.value.applyVideoQualityProperties(.balanced)
                transfer.value.applyVideoRenderProperties()
                continuation.resume()
            }
        }
    }

    @MainActor
    func testMPVWakeupCanEnterEventReaderOffMainThread() async {
        let playerView = MPVPlayerView(frame: .zero)
        let transfer = TestUnsafeTransfer(value: playerView)
        let context = TestUnsafeTransfer(
            value: Unmanaged.passUnretained(playerView).toOpaque()
        )
        let timerHandler = makeMPVTimeTimerHandler(playerView)

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                mpvPlayerWakeupCallback(context.value)
                timerHandler()
                transfer.value.notifyOnMain {
                    XCTAssertTrue(Thread.isMainThread)
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    func testMetalLayerRoutesRendererThreadMutationsToMainThread() async {
        let layer = MPVPlayerMetalLayer()

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                layer.pixelFormat = .bgra8Unorm
                layer.maximumDrawableCount = 3
                layer.drawableSize = CGSize(width: 320, height: 180)
                layer.setNeedsDisplay()
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }

        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)
        XCTAssertEqual(layer.maximumDrawableCount, 3)
        XCTAssertEqual(layer.drawableSize, CGSize(width: 320, height: 180))
    }

    @MainActor
    func testSimulatorSoftwareProfileDisablesLavcDirectRendering() {
        #if targetEnvironment(simulator)
        let playerView = MPVPlayerView(frame: .zero)
        let softwareProfile = playerView.makeSetupProfiles().first {
            $0.name == "metal-software"
        }

        XCTAssertEqual(
            softwareProfile?.options.first { $0.0 == "vd-lavc-dr" }?.1,
            "no"
        )
        #endif
    }

    @MainActor
    func testSimulatorUsesCompatibilityGPURenderer() {
        #if targetEnvironment(simulator)
        let playerView = MPVPlayerView(frame: .zero)
        let softwareProfile = playerView.makeSetupProfiles().first {
            $0.name == "metal-software"
        }
        let options = Dictionary(
            uniqueKeysWithValues: softwareProfile?.options ?? []
        )

        XCTAssertEqual(options["vo"], "gpu")
        XCTAssertEqual(options["gpu-api"], "vulkan")
        XCTAssertEqual(options["gpu-context"], "moltenvk")
        XCTAssertEqual(options["gpu-dumb-mode"], "yes")
        XCTAssertFalse(playerView.usesExtendedDynamicRangeOutput)
        #endif
    }
}
