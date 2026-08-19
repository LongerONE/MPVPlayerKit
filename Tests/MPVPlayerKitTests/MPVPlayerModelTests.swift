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
            debandEnabled: true
        )

        let values = configuration.bridgeDictionary

        XCTAssertEqual(values["url"] as? String, url.absoluteString)
        XCTAssertEqual(values["headers"] as? [String: String], ["Authorization": "Bearer token"])
        XCTAssertEqual(values["userAgent"] as? String, "Tests/1.0")
        XCTAssertEqual((values["forceSoftwareDecode"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values["isDolbyVisionPlayback"] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((values["videoQuality"] as? NSNumber)?.intValue, MPVVideoQuality.highQuality.rawValue)
        XCTAssertEqual((values["debandEnabled"] as? NSNumber)?.boolValue, true)
    }

    func testVideoQualityPresetsUseCompleteTieredRendererOptions() {
        let powerSaving = Dictionary(uniqueKeysWithValues: MPVVideoQualityPreset.powerSaving.options)
        let balanced = Dictionary(uniqueKeysWithValues: MPVVideoQualityPreset.balanced.options)
        let highQuality = Dictionary(uniqueKeysWithValues: MPVVideoQualityPreset.highQuality.options)

        XCTAssertEqual(powerSaving["scale"], "bilinear")
        XCTAssertEqual(powerSaving["cscale"], "bilinear")
        XCTAssertEqual(powerSaving["dscale"], "bilinear")
        XCTAssertEqual(powerSaving["scaler-resizes-only"], "yes")
        XCTAssertEqual(powerSaving["linear-downscaling"], "no")
        XCTAssertEqual(powerSaving["dither"], "no")
        XCTAssertEqual(powerSaving["interpolation"], "no")
        XCTAssertEqual(powerSaving["allow-delayed-peak-detect"], "no")
        XCTAssertEqual(powerSaving["sigmoid-upscaling"], "no")
        XCTAssertEqual(powerSaving["hdr-compute-peak"], "no")

        XCTAssertEqual(balanced["scale"], "lanczos")
        XCTAssertEqual(balanced["cscale"], "bilinear")
        XCTAssertEqual(balanced["dscale"], "mitchell")
        XCTAssertEqual(balanced["scale-antiring"], "0.0")
        XCTAssertEqual(balanced["correct-downscaling"], "no")
        XCTAssertEqual(balanced["linear-downscaling"], "no")
        XCTAssertEqual(balanced["hdr-compute-peak"], "no")
        XCTAssertEqual(balanced["allow-delayed-peak-detect"], "no")
        XCTAssertEqual(balanced["sigmoid-upscaling"], "no")
        XCTAssertEqual(balanced["interpolation"], "no")

        XCTAssertEqual(highQuality["scale"], "ewa_lanczossharp")
        XCTAssertEqual(highQuality["cscale"], "ewa_lanczos")
        XCTAssertEqual(highQuality["dscale"], "lanczos")
        XCTAssertEqual(highQuality["scale-antiring"], "0.6")
        XCTAssertEqual(highQuality["cscale-antiring"], "0.6")
        XCTAssertEqual(highQuality["dscale-antiring"], "0.0")
        XCTAssertEqual(highQuality["hdr-compute-peak"], "yes")
        XCTAssertEqual(highQuality["allow-delayed-peak-detect"], "no")
        XCTAssertEqual(highQuality["linear-downscaling"], "no")
        XCTAssertEqual(highQuality["interpolation"], "no")

        XCTAssertEqual(Set(powerSaving.keys), Set(balanced.keys))
        XCTAssertEqual(Set(balanced.keys), Set(highQuality.keys))
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
    func testDeviceDecodePrefersDirectFramesAndKeepsCopyFallback() {
        let options = Dictionary(
            uniqueKeysWithValues: MPVPlayerView.safeDecodeOptions(
                hardwareDecodeMethod: MPVPlayerView.deviceHardwareDecodeMethod
            )
        )

        XCTAssertEqual(options["hwdec"], "videotoolbox")
        XCTAssertEqual(options["vd-lavc-dr"], "auto")

        let playerView = MPVPlayerView(frame: .zero)
        let profiles = playerView.makeSetupProfiles()
        #if targetEnvironment(simulator)
        XCTAssertEqual(profiles.map(\.name), ["metal-software"])
        #else
        XCTAssertEqual(profiles.map(\.name), [
            "metal-videotoolbox",
            "metal-videotoolbox-copy",
            "metal-software",
        ])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: profiles[1].options)["vd-lavc-dr"],
            "no"
        )
        #endif
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
        XCTAssertEqual(style.shadowColor, "#FF000000")
        XCTAssertEqual(style.bridgeDictionary["shadowColor"] as? String, "#FF000000")
        XCTAssertNil(style.bridgeDictionary["shadowBlur"])
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
                let shouldPrintRenderer = transfer.value.shouldPrintMPVLogMessage(
                    prefix: "vo/gpu-next/libplacebo",
                    level: "verbose",
                    text: "frame upload"
                )
                let shouldPrintDecoder = transfer.value.shouldPrintMPVLogMessage(
                    prefix: "vd/ffmpeg",
                    level: "verbose",
                    text: "decoder frame"
                )
                continuation.resume(
                    returning: shouldPrint && shouldPrintRenderer && shouldPrintDecoder
                )
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
    func testSimulatorAddsDumbModeWhileKeepingAnSDRSurface() {
        #if targetEnvironment(simulator)
        let playerView = MPVPlayerView(frame: .zero)
        let softwareProfile = playerView.makeSetupProfiles().first {
            $0.name == "metal-software"
        }
        let options = Dictionary(
            uniqueKeysWithValues: softwareProfile?.options ?? []
        )

        XCTAssertEqual(options["vo"], "gpu-next")
        XCTAssertEqual(options["gpu-api"], "vulkan")
        XCTAssertEqual(options["gpu-context"], "moltenvk")
        XCTAssertEqual(options["gpu-dumb-mode"], "yes")
        XCTAssertFalse(playerView.usesExtendedDynamicRangeOutput)
        #endif
    }
}
