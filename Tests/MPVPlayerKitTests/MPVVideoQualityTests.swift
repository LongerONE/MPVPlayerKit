import XCTest
@testable import MPVPlayerKit

final class MPVVideoQualityTests: XCTestCase {
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
        XCTAssertEqual(powerSaving["hdr-compute-peak"], "auto")

        XCTAssertEqual(balanced["scale"], "lanczos")
        XCTAssertEqual(balanced["cscale"], "bilinear")
        XCTAssertEqual(balanced["dscale"], "mitchell")
        XCTAssertEqual(balanced["scale-antiring"], "0.0")
        XCTAssertEqual(balanced["correct-downscaling"], "no")
        XCTAssertEqual(balanced["linear-downscaling"], "no")
        XCTAssertEqual(balanced["hdr-compute-peak"], "auto")
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

    func testQualityOptionsOverrideAutomaticColorPolicyForEveryOutputTier() {
        for usesExtendedDynamicRangeOutput in [false, true] {
            let outputMode = MPVColorMappingPolicy.outputMode(
                usesExtendedDynamicRangeOutput: usesExtendedDynamicRangeOutput
            )
            let colorOptions = MPVColorMappingPolicy.options(for: outputMode)

            for quality in [
                MPVVideoQualityPreset.powerSaving,
                .balanced,
                .highQuality,
            ] {
                let options = Dictionary(
                    colorOptions + quality.options,
                    uniquingKeysWith: { _, replacement in replacement }
                )
                let expectedPeak = quality == .highQuality ? "yes" : "auto"

                XCTAssertEqual(options["hdr-compute-peak"], expectedPeak)
                XCTAssertEqual(options["allow-delayed-peak-detect"], "no")
            }
        }
    }
}
