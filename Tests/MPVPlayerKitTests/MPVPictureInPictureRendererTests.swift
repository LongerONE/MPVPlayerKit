import UIKit
import XCTest
@testable import MPVPlayerKit

final class MPVPictureInPictureRendererTests: XCTestCase {
    @MainActor
    func testPictureInPictureRendererInvariantSnapshotSelectsSDREDRAndDolbyVisionProfiles() {
        let playerView = MPVPlayerView(frame: .zero)

        playerView.videoQualityPreset = .highQuality
        for usesExtendedDynamicRangeOutput in [false, true] {
            playerView.usesExtendedDynamicRangeOutput = usesExtendedDynamicRangeOutput
            let highQualityProfileOptions = playerView.makeSetupProfiles().map {
                MPVPictureInPictureRendererInvariantSnapshot.optionMap($0.options)
            }
            XCTAssertFalse(highQualityProfileOptions.isEmpty)
            #if targetEnvironment(simulator)
            // 模拟器固定使用省电缩放器，避免 MoltenVK 大 buffer 分配崩溃。
            XCTAssertTrue(highQualityProfileOptions.allSatisfy {
                $0["hdr-compute-peak"] == "auto"
            })
            XCTAssertEqual(highQualityProfileOptions.first?["scale"], "bilinear")
            #else
            XCTAssertTrue(highQualityProfileOptions.allSatisfy {
                $0["hdr-compute-peak"] == "yes"
            })
            #endif
        }

        playerView.videoQualityPreset = .balanced
        playerView.usesExtendedDynamicRangeOutput = false
        playerView.isDolbyVisionPlayback = false
        let balancedProfileOptions = playerView.makeSetupProfiles().map {
            MPVPictureInPictureRendererInvariantSnapshot.optionMap($0.options)
        }
        XCTAssertTrue(balancedProfileOptions.allSatisfy {
            $0["hdr-compute-peak"] == "auto"
        })
        XCTAssertRendererOptionsAndProfiles(
            playerView: playerView,
            expectedColorOptions: MPVPlayerView.sdrMetalVideoOutputOptions,
            expectedHintMode: nil
        )

        playerView.usesExtendedDynamicRangeOutput = true
        playerView.isDolbyVisionPlayback = false
        #if targetEnvironment(simulator)
        // 模拟器不启用 EDR，refreshColorOutputForTargetScreen 固定 SDR。
        XCTAssertRendererOptionsAndProfiles(
            playerView: playerView,
            expectedColorOptions: MPVPlayerView.sdrMetalVideoOutputOptions,
            expectedHintMode: nil
        )
        #else
        XCTAssertRendererOptionsAndProfiles(
            playerView: playerView,
            expectedColorOptions: MPVPlayerView.edrMetalVideoOutputOptions,
            expectedHintMode: "target"
        )
        #endif

        let regularEDROptions = playerView.metalVideoOutputOptions
        playerView.isDolbyVisionPlayback = true
        #if targetEnvironment(simulator)
        // 模拟器不启用 EDR，颜色输出固定为 SDR-sRGB。
        XCTAssertRendererOptionsAndProfiles(
            playerView: playerView,
            expectedColorOptions: MPVPlayerView.sdrMetalVideoOutputOptions,
            expectedHintMode: nil
        )
        #else
        XCTAssertRendererOptionsAndProfiles(
            playerView: playerView,
            expectedColorOptions: MPVPlayerView.dolbyVisionEDRMetalVideoOutputOptions,
            expectedHintMode: "target"
        )
        #endif
        XCTAssertEqual(
            MPVPictureInPictureRendererInvariantSnapshot.optionMap(
                playerView.metalVideoOutputOptions
            ),
            MPVPictureInPictureRendererInvariantSnapshot.optionMap(regularEDROptions)
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
        #if targetEnvironment(simulator)
        let platformOptions = [("vo", "libmpv")] + expectedColorOptions.filter {
            !["vo", "gpu-api", "gpu-context"].contains($0.0)
        }
        #else
        let platformOptions = expectedColorOptions
        #endif
        let expectedOptions = MPVPictureInPictureRendererInvariantSnapshot.optionMap(platformOptions)
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
