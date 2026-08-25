import XCTest
@testable import MPVPlayerKit

final class MPVColorMappingPolicyTests: XCTestCase {
    func testReferenceHeadroomSelectsSDROutput() {
        XCTAssertFalse(
            MPVColorMappingPolicy.supportsExtendedDynamicRange(
                potentialHeadroom: 1.0
            )
        )
    }

    func testHeadroomAboveReferenceSelectsEDROutput() {
        XCTAssertTrue(
            MPVColorMappingPolicy.supportsExtendedDynamicRange(
                potentialHeadroom: 1.01
            )
        )
    }

    func testDeferredActiveRendererModeIsAppliedByNextSetup() {
        var state = MPVColorOutputState(currentMode: .sdr)

        _ = state.prepareForRendererSetup()
        XCTAssertNil(state.request(.extendedDynamicRange))
        XCTAssertEqual(state.currentMode, .sdr)
        XCTAssertEqual(state.pendingMode, .extendedDynamicRange)

        state.rendererDidStop()
        XCTAssertEqual(state.prepareForRendererSetup(), .extendedDynamicRange)
        XCTAssertEqual(state.currentMode, .extendedDynamicRange)
        XCTAssertNil(state.pendingMode)
        XCTAssertNil(state.prepareForRendererSetup())
    }

    func testLatestScreenRequestReplacesDeferredMode() {
        var state = MPVColorOutputState(currentMode: .sdr)

        _ = state.prepareForRendererSetup()
        XCTAssertNil(state.request(.extendedDynamicRange))
        XCTAssertNil(state.request(.sdr))

        state.rendererDidStop()
        XCTAssertNil(state.prepareForRendererSetup())
        XCTAssertEqual(state.currentMode, .sdr)
        XCTAssertNil(state.pendingMode)
    }

    func testSDRPolicyTargetsReferenceDisplayColorSpace() {
        let options = optionMap(
            MPVColorMappingPolicy.options(for: .sdr)
        )

        XCTAssertEqual(options["target-trc"], "srgb")
        XCTAssertEqual(options["target-prim"], "bt.709")
        XCTAssertNil(options["target-colorspace-hint"])
    }

    func testEDRPolicyUsesTargetAdaptiveAutomaticMapping() {
        let options = optionMap(
            MPVColorMappingPolicy.options(for: .extendedDynamicRange)
        )

        XCTAssertEqual(options["vo"], "gpu-next")
        XCTAssertEqual(options["target-trc"], "linear")
        XCTAssertEqual(options["target-prim"], "bt.709")
        XCTAssertEqual(options["target-colorspace-hint"], "yes")
        XCTAssertEqual(options["target-colorspace-hint-mode"], "target")
        XCTAssertEqual(options["hdr-compute-peak"], "auto")
        XCTAssertEqual(options["gamut-mapping-mode"], "auto")
        XCTAssertNil(options["tone-mapping"])
        XCTAssertNil(options["target-peak"])
        XCTAssertNil(options["target-contrast"])
    }

    func testDolbyVisionHintDoesNotOverrideEDRMapping() {
        XCTAssertEqual(
            optionMap(MPVColorMappingPolicy.dolbyVisionOutputOptions),
            optionMap(MPVColorMappingPolicy.extendedDynamicRangeOutputOptions)
        )
        XCTAssertEqual(
            MPVColorMappingPolicy.contentHint(isDolbyVisionPlayback: true),
            .dolbyVision
        )
        XCTAssertEqual(
            MPVColorMappingPolicy.contentHint(isDolbyVisionPlayback: false),
            .unspecified
        )
    }

    private func optionMap(_ options: [(String, String)]) -> [String: String] {
        Dictionary(options, uniquingKeysWith: { _, replacement in replacement })
    }
}
