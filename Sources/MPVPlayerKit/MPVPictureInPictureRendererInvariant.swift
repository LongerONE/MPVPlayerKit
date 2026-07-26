import Foundation
import QuartzCore

/// A read-only record of the renderer state PiP must never reconfigure.
///
/// The PiP lifecycle cannot be driven reliably in unit tests because the
/// system controller is unavailable on the simulator. Keeping this snapshot
/// internal lets those tests compare the protected state before and after any
/// lifecycle operation without exposing new application API.
struct MPVPictureInPictureRendererInvariantSnapshot: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let name: String
        let value: String
    }

    struct SetupProfile: Equatable, Sendable {
        let name: String
        /// Keeps the exact option order passed to libmpv. The order is part of
        /// the setup contract because later options may override earlier ones.
        let orderedOptions: [Option]

        var options: [String: String] {
            MPVPictureInPictureRendererInvariantSnapshot.optionMap(orderedOptions)
        }

        init(_ profile: MPVSetupProfile) {
            name = profile.name
            orderedOptions = profile.options.map { Option(name: $0.0, value: $0.1) }
        }
    }

    let selectedVideoOutputOptions: [String: String]
    /// A queue-written mirror of the profiles actually being attempted. It is
    /// intentionally empty before MPV initialization begins.
    let runtimeSetupProfiles: [SetupProfile]
    let runtimeActiveSetupProfileIndex: Int
    let usesExtendedDynamicRangeOutput: Bool
    let metalLayerIdentifier: ObjectIdentifier
    let metalLayerSuperlayerIdentifier: ObjectIdentifier?
    let metalPixelFormat: UInt
    let metalColorSpaceName: String?
    let metalWantsExtendedDynamicRangeContent: Bool
    let metalFramebufferOnly: Bool

    @MainActor
    init(playerView: MPVPlayerView) {
        let runtimeState = playerView.pictureInPictureRendererRuntimeState.snapshot()
        selectedVideoOutputOptions = Self.optionMap(playerView.metalVideoOutputOptions)
        runtimeSetupProfiles = runtimeState.profiles
        runtimeActiveSetupProfileIndex = runtimeState.activeProfileIndex
        usesExtendedDynamicRangeOutput = playerView.usesExtendedDynamicRangeOutput
        metalLayerIdentifier = ObjectIdentifier(playerView.metalLayer)
        metalLayerSuperlayerIdentifier = playerView.metalLayer.superlayer.map(ObjectIdentifier.init)
        metalPixelFormat = playerView.metalLayer.pixelFormat.rawValue
        metalColorSpaceName = playerView.metalLayer.colorspace?.name as String?
        if #available(iOS 16.0, *) {
            metalWantsExtendedDynamicRangeContent =
                playerView.metalLayer.wantsExtendedDynamicRangeContent
        } else {
            metalWantsExtendedDynamicRangeContent = false
        }
        metalFramebufferOnly = playerView.metalLayer.framebufferOnly
    }

    static func optionMap(_ options: [(String, String)]) -> [String: String] {
        options.reduce(into: [:]) { result, option in
            result[option.0] = option.1
        }
    }

    static func optionMap(_ options: [Option]) -> [String: String] {
        options.reduce(into: [:]) { result, option in
            result[option.name] = option.value
        }
    }
}

/// Keeps a copyable runtime record without making a main-actor caller wait for
/// the MPV queue. Writers can originate from the MPV and main queues; the lock
/// serializes their updates, while readers only hold it to copy immutable values.
final class MPVPictureInPictureRendererRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [MPVPictureInPictureRendererInvariantSnapshot.SetupProfile] = []
    private var activeProfileIndex = 0

    func store(
        profiles: [MPVPictureInPictureRendererInvariantSnapshot.SetupProfile],
        activeProfileIndex: Int
    ) {
        lock.lock()
        self.profiles = profiles
        self.activeProfileIndex = activeProfileIndex
        lock.unlock()
    }

    func setActiveProfileIndex(_ activeProfileIndex: Int) {
        lock.lock()
        self.activeProfileIndex = activeProfileIndex
        lock.unlock()
    }

    func reset() {
        lock.lock()
        profiles = []
        activeProfileIndex = 0
        lock.unlock()
    }

    func snapshot() -> (
        profiles: [MPVPictureInPictureRendererInvariantSnapshot.SetupProfile],
        activeProfileIndex: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (profiles, activeProfileIndex)
    }
}

extension MPVPlayerView {
    /// Captures state that PiP frame production must not change.
    @MainActor
    func pictureInPictureRendererInvariantSnapshot()
        -> MPVPictureInPictureRendererInvariantSnapshot
    {
        MPVPictureInPictureRendererInvariantSnapshot(playerView: self)
    }
}
