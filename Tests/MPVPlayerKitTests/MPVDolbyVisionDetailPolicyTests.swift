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

    func testDolbyVisionAndStandardCommandsUseNeutralValues() {
        let dolbyVision = commandMap(
            MPVDolbyVisionDetailPolicy.commands(isDolbyVision: true)
        )
        let standard = commandMap(
            MPVDolbyVisionDetailPolicy.commands(isDolbyVision: false)
        )

        XCTAssertEqual(dolbyVision, standard)
        XCTAssertEqual(dolbyVision["gamma"], "0")
        XCTAssertEqual(dolbyVision["contrast"], "0")
        XCTAssertEqual(dolbyVision["hdr-contrast-recovery"], "0")
        XCTAssertEqual(dolbyVision["hdr-contrast-smoothness"], "3.5")
        XCTAssertEqual(standard["gamma"], "0")
        XCTAssertEqual(standard["contrast"], "0")
        XCTAssertEqual(standard["hdr-contrast-recovery"], "0")
        XCTAssertEqual(standard["hdr-contrast-smoothness"], "3.5")
        XCTAssertNil(dolbyVision["tone-mapping"])
        XCTAssertNil(dolbyVision["gamut-mapping-mode"])
        XCTAssertNil(dolbyVision["hdr-compute-peak"])
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

    private func commandMap(
        _ commands: [MPVDolbyVisionDetailCommand]
    ) -> [String: String] {
        Dictionary(
            commands.map { ($0.property, $0.value) },
            uniquingKeysWith: { _, replacement in replacement }
        )
    }

}
