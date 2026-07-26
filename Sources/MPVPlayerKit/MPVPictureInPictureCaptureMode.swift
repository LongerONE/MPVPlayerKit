import Foundation

/// How Picture in Picture frames are captured from MPV.
@objc public enum MPVPictureInPictureCaptureMode: Int, Sendable {
    /// Captures the raw video image and draws the current subtitle line into it.
    ///
    /// The default. `screenshot-raw video` never runs a video output render
    /// pass, so it works while the Metal layer is not presenting, at the cost
    /// of reading back the full video resolution and of approximating MPV's
    /// subtitle rendering.
    case videoWithSubtitleOverlay = 0

    /// Captures what MPV renders into its window, cropped to the video area.
    ///
    /// MPV composites its own subtitles, fit/fill cropping and tone mapping, so
    /// the window matches the inline player exactly, and the read back frame is
    /// the size of the drawable rather than of the video.
    ///
    /// Experimental: this mode needs a video output render pass, which crashed
    /// on the builds that led to the video mode above. Opt in and verify on
    /// device before relying on it.
    case window = 1
}
