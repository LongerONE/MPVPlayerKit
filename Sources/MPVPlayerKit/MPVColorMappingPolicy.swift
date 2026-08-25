import Foundation

/// The display pipeline selected for libplacebo output.
enum MPVColorOutputMode: Sendable {
    case sdr
    case extendedDynamicRange
}

/// Tracks a display-mode request across asynchronous renderer teardown.
struct MPVColorOutputState: Equatable, Sendable {
    private(set) var currentMode: MPVColorOutputMode
    private(set) var pendingMode: MPVColorOutputMode?
    private(set) var rendererIsReserved = false

    init(currentMode: MPVColorOutputMode = .sdr) {
        self.currentMode = currentMode
    }

    /// Returns a mode that can be applied immediately. Active renderers retain
    /// their swapchain while the request is saved for the next setup.
    mutating func request(
        _ desiredMode: MPVColorOutputMode
    ) -> MPVColorOutputMode? {
        guard rendererIsReserved == false else {
            pendingMode = desiredMode
            return nil
        }
        pendingMode = nil
        guard desiredMode != currentMode else { return nil }
        currentMode = desiredMode
        return desiredMode
    }

    /// Consumes a deferred request immediately before renderer construction.
    mutating func prepareForRendererSetup() -> MPVColorOutputMode? {
        rendererIsReserved = true
        guard let pendingMode else { return nil }
        self.pendingMode = nil
        guard pendingMode != currentMode else { return nil }
        currentMode = pendingMode
        return pendingMode
    }

    mutating func rendererDidStop() {
        rendererIsReserved = false
    }
}

/// Host-provided media metadata used for diagnostics only.
///
/// libmpv/libplacebo remains responsible for inspecting the actual frame
/// metadata. A stale host hint must never select a different tone-mapping
/// algorithm or a different set of luminance constants.
enum MPVContentColorHint: String, Sendable {
    case unspecified
    case dolbyVision
}

/// Pure option policy for mpv 0.41's `gpu-next` renderer.
///
/// Color conversion is selected from the display capability. HDR10, HLG and
/// Dolby Vision therefore take the same metadata-driven EDR path, allowing
/// libplacebo to use source metadata and the advertised render target instead
/// of application-tuned luminance guesses.
///
/// The bundled mpv 0.41/libplacebo 7.360.1 stack can map Dolby Vision profiles
/// whose residual is disabled (P5/P8, MEL or base-layer-only input). It does
/// not compose a Profile 7 FEL enhancement layer; this policy must not be read
/// as adding FEL decoding support.
struct MPVColorMappingPolicy {
    /// A headroom of exactly 1.0 is the SDR reference range. Only a finite
    /// value above it means the target display can present EDR content.
    static func supportsExtendedDynamicRange(potentialHeadroom: CGFloat) -> Bool {
        potentialHeadroom.isFinite && potentialHeadroom > 1.0
    }

    /// Renderer options that are independent of the display dynamic range.
    static let commonRendererOptions: [(String, String)] = [
        ("vo", "gpu-next"),
        ("gpu-api", "vulkan"),
        ("gpu-context", "moltenvk"),
        ("blend-subtitles", "video"),
        ("sub-hdr-peak", "100"),
        ("image-subs-hdr-peak", "100"),
        ("gpu-shader-cache", "yes"),
        ("demuxer-hysteresis-secs", "10"),
    ]

    /// Keep libplacebo's automatic mapping and peak-detection behavior.
    /// Target peak and contrast are intentionally omitted so the render target
    /// and its defaults determine them.
    static let automaticColorMappingOptions: [(String, String)] = [
        ("hdr-compute-peak", "auto"),
        ("gamut-mapping-mode", "auto"),
    ]

    static let sdrOutputOptions =
        commonRendererOptions + automaticColorMappingOptions + [
            ("target-trc", "srgb"),
            ("target-prim", "bt.709"),
        ]

    /// Advertise the mapped render target rather than copying source metadata
    /// to the swapchain. This lets gpu-next reshape every original HDR source,
    /// including Dolby Vision, for the current EDR display target.
    static let extendedDynamicRangeOutputOptions =
        commonRendererOptions + automaticColorMappingOptions + [
            ("fbo-format", "rgba16f"),
            // MPV's target must match the Metal layer's extendedLinearSRGB
            // colorspace. Leaving these as auto can fall back to source HDR
            // metadata when the display target is unavailable to gpu-next.
            ("target-trc", "linear"),
            ("target-prim", "bt.709"),
            ("target-colorspace-hint", "yes"),
            ("target-colorspace-hint-mode", "target"),
        ]

    /// Dolby Vision deliberately shares the adaptive EDR policy. The named
    /// alias documents that host Dolby Vision metadata is not a rendering
    /// override.
    static let dolbyVisionOutputOptions = extendedDynamicRangeOutputOptions

    static func outputMode(usesExtendedDynamicRangeOutput: Bool) -> MPVColorOutputMode {
        usesExtendedDynamicRangeOutput ? .extendedDynamicRange : .sdr
    }

    static func contentHint(isDolbyVisionPlayback: Bool) -> MPVContentColorHint {
        isDolbyVisionPlayback ? .dolbyVision : .unspecified
    }

    static func options(for outputMode: MPVColorOutputMode) -> [(String, String)] {
        switch outputMode {
        case .sdr:
            sdrOutputOptions
        case .extendedDynamicRange:
            extendedDynamicRangeOutputOptions
        }
    }
}

extension MPVPlayerView {
    static let sharedMetalVideoOutputOptions =
        MPVColorMappingPolicy.commonRendererOptions
        + MPVColorMappingPolicy.automaticColorMappingOptions
    static let sdrMetalVideoOutputOptions = MPVColorMappingPolicy.sdrOutputOptions
    static let edrMetalVideoOutputOptions =
        MPVColorMappingPolicy.extendedDynamicRangeOutputOptions
    static let dolbyVisionEDRMetalVideoOutputOptions =
        MPVColorMappingPolicy.dolbyVisionOutputOptions
}
