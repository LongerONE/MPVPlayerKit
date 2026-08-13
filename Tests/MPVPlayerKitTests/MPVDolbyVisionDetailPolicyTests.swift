import XCTest
@testable import MPVPlayerKit

final class MPVDolbyVisionDetailPolicyTests: XCTestCase {
    func testColorMatrixProducesThreeDistinctObservations() {
        XCTAssertEqual(
            MPVDolbyVisionDetailPolicy.observation(colorMatrix: "dolbyvision"),
            .dolbyVision
        )
        XCTAssertEqual(
            MPVDolbyVisionDetailPolicy.observation(colorMatrix: "bt.2020-ncl"),
            .nonDolbyVision
        )
        XCTAssertEqual(
            MPVDolbyVisionDetailPolicy.observation(colorMatrix: nil),
            .unavailable
        )
    }

    func testFirstUnknownUsesOnlyPositivePerHandleHint() {
        var hinted = MPVDolbyVisionDetailRuntimeState()
        hinted.resetForNewHandle(hostHint: true)
        XCTAssertEqual(hinted.desiredEnhancement(for: .unavailable), true)

        var unhinted = MPVDolbyVisionDetailRuntimeState()
        unhinted.resetForNewHandle(hostHint: false)
        XCTAssertNil(unhinted.desiredEnhancement(for: .unavailable))
    }

    func testUnavailableKeepsLatestActualDolbyDecision() {
        var state = MPVDolbyVisionDetailRuntimeState()
        state.resetForNewHandle(hostHint: false)

        XCTAssertEqual(state.desiredEnhancement(for: .dolbyVision), true)
        XCTAssertEqual(state.desiredEnhancement(for: .unavailable), true)
    }

    func testUnavailableKeepsLatestActualNonDolbyDecision() {
        var state = MPVDolbyVisionDetailRuntimeState()
        state.resetForNewHandle(hostHint: true)

        XCTAssertEqual(state.desiredEnhancement(for: .nonDolbyVision), false)
        XCTAssertEqual(state.desiredEnhancement(for: .unavailable), false)
    }

    func testActualNonDolbyCorrectsStalePositiveHint() {
        var state = MPVDolbyVisionDetailRuntimeState()
        state.resetForNewHandle(hostHint: true)

        XCTAssertEqual(state.desiredEnhancement(for: .unavailable), true)
        XCTAssertEqual(state.desiredEnhancement(for: .nonDolbyVision), false)
    }

    func testEnhancedAndStandardCommandsHaveExpectedValues() {
        let enhanced = commandMap(
            MPVDolbyVisionDetailPolicy.commands(isDolbyVision: true)
        )
        let standard = commandMap(
            MPVDolbyVisionDetailPolicy.commands(isDolbyVision: false)
        )

        XCTAssertEqual(enhanced["gamma"], "7")
        XCTAssertEqual(enhanced["contrast"], "-7")
        XCTAssertEqual(enhanced["hdr-contrast-recovery"], "0.30")
        XCTAssertEqual(enhanced["hdr-contrast-smoothness"], "3.5")
        XCTAssertEqual(standard["gamma"], "0")
        XCTAssertEqual(standard["contrast"], "0")
        XCTAssertEqual(standard["hdr-contrast-recovery"], "0")
        XCTAssertEqual(standard["hdr-contrast-smoothness"], "3.5")
        XCTAssertNil(enhanced["tone-mapping"])
        XCTAssertNil(enhanced["gamut-mapping-mode"])
        XCTAssertNil(enhanced["hdr-compute-peak"])
    }

    func testPartialSuccessRetriesOnlyFailedProperties() throws {
        var state = MPVDolbyVisionDetailRuntimeState()
        state.resetForNewHandle(hostHint: false)
        let initial = state.commands(to: true)
        XCTAssertEqual(initial.count, 4)

        for update in initial {
            state.record(
                update,
                succeeded: update.property != "hdr-contrast-recovery"
            )
        }
        let retry = state.commands(to: true)
        XCTAssertEqual(retry.map(\.property), ["hdr-contrast-recovery"])

        state.record(try XCTUnwrap(retry.first), succeeded: true)
        XCTAssertTrue(state.commands(to: true).isEmpty)
    }

    func testNewHandleResetDoesNotReuseActualOrEnhancedState() {
        var state = MPVDolbyVisionDetailRuntimeState()
        state.resetForNewHandle(hostHint: true)
        _ = state.desiredEnhancement(for: .dolbyVision)
        for update in state.commands(to: true) {
            state.record(update, succeeded: true)
        }

        state.resetForNewHandle(hostHint: false)
        XCTAssertNil(state.lastActualDetection)
        XCTAssertNil(state.desiredEnhancement(for: .unavailable))
        XCTAssertEqual(state.commands(to: false).count, 4)
    }

    func testEnhancedCurveLiftsShadowsAndSoftensWhite() {
        let oldCurve: (Double) -> Double = {
            self.modeledEqualizerOutput(input: $0, gamma: 3, contrast: 0)
        }
        let enhancedCurve: (Double) -> Double = {
            self.modeledEqualizerOutput(input: $0, gamma: 7, contrast: -7)
        }
        let black = enhancedCurve(0)
        let white = enhancedCurve(1)

        XCTAssertEqual(black, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            white,
            modeledEqualizerOutput(input: 1, gamma: 7, contrast: -7),
            accuracy: 0.000_001
        )
        XCTAssertEqual(white, 0.9392, accuracy: 0.000_1)
        XCTAssertGreaterThan(enhancedCurve(0.10), oldCurve(0.10))
        XCTAssertGreaterThan(enhancedCurve(0.30), oldCurve(0.30))
        XCTAssertLessThan(enhancedCurve(0.50), oldCurve(0.50))
        XCTAssertLessThan(enhancedCurve(0.75), oldCurve(0.75) - 0.02)
        XCTAssertLessThan(white, oldCurve(1) - 0.05)
    }

    private func commandMap(
        _ commands: [MPVDolbyVisionDetailCommand]
    ) -> [String: String] {
        Dictionary(
            commands.map { ($0.property, $0.value) },
            uniquingKeysWith: { _, replacement in replacement }
        )
    }

    /// Models mpv's normalized equalizer transfer for endpoint/regression checks.
    private func modeledEqualizerOutput(
        input: Double,
        gamma: Double,
        contrast: Double
    ) -> Double {
        let contrasted = max(0, input * (1 + contrast / 100))
        let gammaExponent = 1 / pow(8, gamma / 100)
        return pow(contrasted, gammaExponent)
    }
}
