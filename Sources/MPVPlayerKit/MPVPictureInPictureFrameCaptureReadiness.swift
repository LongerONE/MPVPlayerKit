import CoreGraphics

enum MPVPictureInPictureFrameCaptureReadiness {
    /// `screenshot-raw` returns MPV_ERROR_NOTHING_TO_PLAY while MPV has not
    /// produced a video frame. `readyToPlay` is deliberately not used here:
    /// it depends on a finite duration, which live streams do not have.
    ///
    /// A usable first frame instead requires MPV's raw `video-out-params`
    /// dimensions and either a playback restart or video reconfiguration. The
    /// latter two events mean the dimensions belong to the current video
    /// output, rather than a fallback PiP content size.
    nonisolated static func shouldCapture(
        hasValidVideoOutputParameters: Bool,
        hasPlaybackOrReconfigurationSignal: Bool,
        isPlaying: Bool,
        isWaitingForStart: Bool
    ) -> Bool {
        guard hasValidVideoOutputParameters,
              hasPlaybackOrReconfigurationSignal
        else { return false }
        return isPlaying || isWaitingForStart
    }
}
