import Foundation

extension MPVPlayerView {
    /// Keep decoded VideoToolbox surfaces on the GPU path first. The copy
    /// profile remains available because some libmpv/MoltenVK combinations
    /// cannot safely import the decoder surface for every HEVC/Dolby Vision
    /// stream.
    nonisolated static let deviceHardwareDecodeMethod = "videotoolbox"
    nonisolated static let deviceCopyHardwareDecodeMethod = "videotoolbox-copy"
    /// A hard safety cap for demuxer packet metadata. `cache-secs` is a time
    /// target and can still represent a large byte range for high-bitrate
    /// media, so keep a bounded memory budget as well.
    nonisolated static let demuxerMaxBytes = "256MiB"
    /// Do not retain an additional unbounded-looking past range while the
    /// player is already using a forward cache.
    nonisolated static let demuxerMaxBackBytes = "0"
    nonisolated static let mpvErrorOptionNotFound: CInt = -5
    /// Simulator / power-saving tuning knobs that may be absent in a given MPVKit build.
    nonisolated static let optionalSetupOptionNames: Set<String> = [
        "video-max-x",
        "video-max-y",
        "gpu-dumb-mode",
        "vd-lavc-threads",
        "demuxer-hysteresis-secs",
        "demuxer-lavf-o",
        "cache-on-disk",
        "vf",
        "network-timeout",
        "stream-lavf-o",
        "hls-bitrate",
    ]
    /// Portable resolution cap for simulator (video-max-x/y unavailable in MPVKit 1.0.0).
    nonisolated static let simulatorResolutionLimitFilter =
        "scale=1280:720"
    /// Preferred runtime vf candidates when option-stage `vf` cannot be applied.
    /// Simpler native scale first — lavfi may leave HEVC track unselected / vo empty on simulator.
    nonisolated static let simulatorResolutionLimitCandidates = [
        "scale=1280:720",
        "scale=w=min(1280\\,iw):h=min(720\\,ih)",
        "lavfi=[scale=w=min(1280,iw):h=min(720,ih)]",
    ]
    nonisolated static func safeDecodeOptions(
        hardwareDecodeMethod: String
    ) -> [(String, String)] {
        let directRendering = hardwareDecodeMethod == deviceHardwareDecodeMethod ? "auto" : "no"
        return [
            ("hwdec", hardwareDecodeMethod),
            // Direct VideoToolbox decoding avoids a 4K frame copy. The copy
            // fallback explicitly disables direct rendering to keep the
            // staging-buffer lifetime safe on older devices/builds.
            ("vd-lavc-dr", directRendering),
        ]
    }
}
