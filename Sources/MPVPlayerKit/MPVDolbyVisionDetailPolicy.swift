import Foundation

/// A runtime mpv property update. These are deliberately not renderer setup
/// options: the selected file's frame metadata is not available until load.
struct MPVDolbyVisionDetailCommand: Equatable, Sendable {
    let property: String
    let value: String
}

enum MPVDolbyVisionFrameObservation: Equatable, Sendable {
    case dolbyVision
    case nonDolbyVision
    case unavailable
}

/// Pure Dolby Vision detection and frame-property policy for bundled mpv 0.41.
struct MPVDolbyVisionDetailPolicy {
    static let colorMatrixProperty = "video-params/colormatrix"
    static let dolbyVisionColorMatrix = "dolbyvision"

    /// Keep Dolby Vision on mpv/libplacebo's metadata-driven color pipeline.
    /// These explicit neutral values also reset a reused handle when the
    /// decoded stream changes between Dolby Vision and ordinary HDR/SDR.
    static let dolbyVisionCommands = [
        MPVDolbyVisionDetailCommand(property: "gamma", value: "0"),
        MPVDolbyVisionDetailCommand(property: "contrast", value: "0"),
        MPVDolbyVisionDetailCommand(property: "hdr-contrast-recovery", value: "0"),
        MPVDolbyVisionDetailCommand(property: "hdr-contrast-smoothness", value: "3.5"),
    ]

    static let standardCommands = dolbyVisionCommands

    static func observation(colorMatrix: String?) -> MPVDolbyVisionFrameObservation {
        guard let normalizedColorMatrix = colorMatrix?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), normalizedColorMatrix.isEmpty == false else {
            return .unavailable
        }
        return normalizedColorMatrix == dolbyVisionColorMatrix
            ? .dolbyVision
            : .nonDolbyVision
    }

    static func commands(isDolbyVision: Bool) -> [MPVDolbyVisionDetailCommand] {
        isDolbyVision ? dolbyVisionCommands : standardCommands
    }
}

/// Queue-confined detection and per-property convergence state.
struct MPVDolbyVisionDetailRuntimeState: Equatable, Sendable {
    private(set) var hostHint = false
    private(set) var lastActualDetection: Bool?
    private(set) var appliedValues: [String: String] = [:]

    mutating func resetForNewHandle(hostHint: Bool) {
        self.hostHint = hostHint
        lastActualDetection = nil
        // Do not assume property writes survived handle replacement. The first
        // reliable decision explicitly establishes all four values.
        appliedValues = [:]
    }

    /// An actual frame result always wins. If metadata temporarily disappears,
    /// retain the latest actual decision. Only the first unknown observation
    /// may use a positive host hint; false is not treated as a reliable denial.
    mutating func desiredEnhancement(
        for observation: MPVDolbyVisionFrameObservation
    ) -> Bool? {
        switch observation {
        case .dolbyVision:
            lastActualDetection = true
            return true
        case .nonDolbyVision:
            lastActualDetection = false
            return false
        case .unavailable:
            return lastActualDetection ?? (hostHint ? true : nil)
        }
    }

    func commands(to desiredValue: Bool) -> [MPVDolbyVisionDetailCommand] {
        MPVDolbyVisionDetailPolicy.commands(isDolbyVision: desiredValue).filter {
            appliedValues[$0.property] != $0.value
        }
    }

    mutating func record(_ command: MPVDolbyVisionDetailCommand, succeeded: Bool) {
        guard succeeded else { return }
        appliedValues[command.property] = command.value
    }
}

extension MPVPlayerView {
    nonisolated func storeConfiguredDolbyVisionHint(_ value: Bool) {
        dolbyVisionConfigurationLock.lock()
        configuredDolbyVisionHint = value
        dolbyVisionConfigurationLock.unlock()
    }

    nonisolated func configuredDolbyVisionHintSnapshot() -> Bool {
        dolbyVisionConfigurationLock.lock()
        defer { dolbyVisionConfigurationLock.unlock() }
        return configuredDolbyVisionHint
    }

    /// Reads actual decoded-frame metadata and converges properties on the same
    /// serial queue used by event handling and all other mpv calls.
    nonisolated func refreshDolbyVisionDetailMapping(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        let colorMatrix = getString(MPVDolbyVisionDetailPolicy.colorMatrixProperty)
        let observation = MPVDolbyVisionDetailPolicy.observation(
            colorMatrix: colorMatrix
        )
        guard let desiredEnhancement = dolbyVisionDetailRuntimeState
            .desiredEnhancement(for: observation) else {
            mpvDebugLog(
                "dolby vision detail mapping deferred reason=\(reason) observation=unavailable"
            )
            return
        }
        let updates = dolbyVisionDetailRuntimeState.commands(
            to: desiredEnhancement
        )
        guard updates.isEmpty == false else { return }

        var failedProperties: [String] = []
        for update in updates {
            let succeeded = command(
                "set",
                args: [update.property, update.value],
                checkForErrors: false
            ) >= 0
            dolbyVisionDetailRuntimeState.record(update, succeeded: succeeded)
            if succeeded == false {
                failedProperties.append(update.property)
            }
        }
        let remaining = dolbyVisionDetailRuntimeState.commands(
            to: desiredEnhancement
        )
        mpvDebugLog(
            "dolby vision detail mapping convergence reason=\(reason) "
                + "desired=\(desiredEnhancement) observation=\(observation) "
                + "colorMatrix=\(colorMatrix ?? "<unavailable>") "
                + "failed=\(failedProperties) remaining=\(remaining.map(\.property))"
        )
    }
}
