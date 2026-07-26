import CoreMedia
import Foundation

/// The area of a captured frame that holds the video.
struct MPVPictureInPictureCropRect: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    static func full(width: Int, height: Int) -> MPVPictureInPictureCropRect {
        MPVPictureInPictureCropRect(x: 0, y: 0, width: width, height: height)
    }
}

/// Locates the video inside a captured frame.
///
/// A window screenshot covers the whole drawable, so the video sits inside the
/// letterbox borders MPV reports through `osd-dimensions`. Those margins are
/// only trusted when they agree with the display aspect ratio MPV reports for
/// the video: unavailable margins would otherwise leave the black bars in the
/// frame, which would give the Picture in Picture window the shape of the
/// drawable instead of the shape of the video.
enum MPVPictureInPictureVideoRect {
    /// Relative aspect difference still considered a match.
    static let aspectTolerance = 0.02

    static func resolve(
        frameWidth: Int,
        frameHeight: Int,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
        displayWidth: Int,
        displayHeight: Int
    ) -> MPVPictureInPictureCropRect {
        let margins = marginRect(
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            left: left,
            top: top,
            right: right,
            bottom: bottom
        )
        guard let displayAspect = aspect(width: displayWidth, height: displayHeight),
              let marginAspect = aspect(width: margins.width, height: margins.height)
        else { return margins }
        guard abs(marginAspect / displayAspect - 1) > aspectTolerance else { return margins }
        // MPV centres the video in its window, so the rect of the display
        // aspect centred in the frame is the video, black bars excluded.
        return centeredRect(
            aspect: displayAspect,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        )
    }

    static func marginRect(
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

    static func centeredRect(
        aspect: Double,
        frameWidth: Int,
        frameHeight: Int
    ) -> MPVPictureInPictureCropRect {
        guard frameWidth > 0, frameHeight > 0, aspect.isFinite, aspect > 0 else {
            return .full(width: max(1, frameWidth), height: max(1, frameHeight))
        }
        var width = frameWidth
        var height = Int((Double(frameWidth) / aspect).rounded())
        if height > frameHeight {
            height = frameHeight
            width = Int((Double(frameHeight) * aspect).rounded())
        }
        width = min(frameWidth, max(1, width))
        height = min(frameHeight, max(1, height))
        return MPVPictureInPictureCropRect(
            x: (frameWidth - width) / 2,
            y: (frameHeight - height) / 2,
            width: width,
            height: height
        )
    }

    static func aspect(width: Int, height: Int) -> Double? {
        guard width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}

/// Size of the converted Picture in Picture frame.
///
/// AVKit takes the shape of the Picture in Picture window from the sample
/// buffers, so the output carries the display aspect ratio MPV reports rather
/// than the storage aspect ratio of the screenshot. Anamorphic video is stored
/// with non-square pixels, so those two differ.
enum MPVPictureInPictureOutputSize {
    static func resolve(
        cropWidth: Int,
        cropHeight: Int,
        displayWidth: Int,
        displayHeight: Int,
        renderSize: CMVideoDimensions
    ) -> (width: Int, height: Int) {
        guard cropWidth > 0, cropHeight > 0 else { return (1, 1) }
        let cropAspect = Double(cropWidth) / Double(cropHeight)
        let aspect = MPVPictureInPictureVideoRect.aspect(
            width: displayWidth,
            height: displayHeight
        ) ?? cropAspect
        // Correct the aspect by shrinking one side, never by upscaling the
        // other, so a wider display aspect does not cost extra pixels.
        var width = Double(cropWidth)
        var height = Double(cropHeight)
        if aspect >= cropAspect {
            height = width / aspect
        } else {
            width = height * aspect
        }
        if renderSize.width > 0, renderSize.height > 0 {
            let scale = min(
                1,
                Double(renderSize.width) / width,
                Double(renderSize.height) / height
            )
            width *= scale
            height *= scale
        }
        return (
            max(1, Int(width.rounded(.down))),
            max(1, Int(height.rounded(.down)))
        )
    }
}
