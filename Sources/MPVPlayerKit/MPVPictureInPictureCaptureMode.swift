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

/// The video area inside a window screenshot.
struct MPVPictureInPictureCropRect: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    static func full(width: Int, height: Int) -> MPVPictureInPictureCropRect {
        MPVPictureInPictureCropRect(x: 0, y: 0, width: width, height: height)
    }
}

/// A window screenshot covers the whole drawable, so the video sits inside the
/// letterbox borders MPV reports through `osd-dimensions`. Cropping to them
/// keeps the Picture in Picture aspect ratio and drops the black bars.
enum MPVPictureInPictureWindowCrop {
    static func resolve(
        frameWidth: Int,
        frameHeight: Int,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int
    ) -> MPVPictureInPictureCropRect {
        let full = MPVPictureInPictureCropRect.full(width: frameWidth, height: frameHeight)
        guard frameWidth > 0, frameHeight > 0,
              left >= 0, top >= 0, right >= 0, bottom >= 0
        else { return full }
        let width = frameWidth - left - right
        let height = frameHeight - top - bottom
        guard width > 0, height > 0 else { return full }
        return MPVPictureInPictureCropRect(x: left, y: top, width: width, height: height)
    }
}
