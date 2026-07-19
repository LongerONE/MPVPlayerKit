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

    func testQuickPlayerCanStartAndRemainLockedInLandscape() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let controller = MPVQuickPlayerViewController(
            url: url,
            autoplay: false,
            forceLandscape: true
        )

        XCTAssertTrue(controller.isLandscapeForced)
        XCTAssertEqual(controller.supportedInterfaceOrientations, .landscapeRight)
        XCTAssertEqual(controller.preferredInterfaceOrientationForPresentation, .landscapeRight)

        controller.setForceLandscape(false)

        XCTAssertFalse(controller.isLandscapeForced)
        XCTAssertEqual(controller.supportedInterfaceOrientations, .all)
        XCTAssertEqual(controller.preferredInterfaceOrientationForPresentation, .portrait)
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
