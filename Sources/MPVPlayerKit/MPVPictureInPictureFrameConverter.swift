import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo

/// One converted Picture in Picture frame, ready to enqueue.
struct MPVPictureInPictureCapture: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let presentationTime: TimeInterval
    let videoFrameRate: Double
    let sourceWidth: Int
    let sourceHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let hasSubtitleOverlay: Bool
    /// Geometry of the drawn subtitle, for comparing against the inline player.
    let subtitleLayout: MPVPictureInPictureSubtitleLayout?
    let screenshotDuration: TimeInterval
    let conversionDuration: TimeInterval
}

/// Raw `screenshot-raw` output, valid only while MPV owns the command result.
struct MPVPictureInPictureRawFrame {
    let width: Int
    let height: Int
    let stride: Int
    let pixels: UnsafeRawPointer
    let byteCount: Int
    let presentationTime: TimeInterval
    let videoFrameRate: Double
    let subtitleText: String?
    let subtitleStyle: MPVPictureInPictureSubtitleStyle
}

/// Bounds the pixels a Picture in Picture frame is converted at.
///
/// AVKit reports the window size only once Picture in Picture is running. Until
/// then a 4K screenshot would be converted, composited and enqueued at its full
/// resolution, which costs about ten times the work the window can show and
/// delays the first frame the system waits for.
enum MPVPictureInPictureRenderBudget {
    static let maximumWidth: Int32 = 1280
    static let maximumHeight: Int32 = 720
    /// Relative change in the reported window size worth a new frame.
    static let significantChangeRatio = 0.1

    static var `default`: CMVideoDimensions {
        CMVideoDimensions(width: maximumWidth, height: maximumHeight)
    }

    /// AVKit reports the size of its window layer, which iOS measures in
    /// points: a 370-point wide window covers 1110 pixels on a 3x screen.
    /// Converting frames at that point size would make the Picture in Picture
    /// window three times softer than the inline player, so scale up to native
    /// pixels and keep the budget as the ceiling.
    static func resolve(
        reportedRenderSize: CMVideoDimensions,
        screenScale: CGFloat = 1
    ) -> CMVideoDimensions {
        guard reportedRenderSize.width > 0, reportedRenderSize.height > 0 else {
            return `default`
        }
        let scale = max(1, Double(screenScale))
        return CMVideoDimensions(
            width: Int32(min(Double(maximumWidth), Double(reportedRenderSize.width) * scale)
                .rounded()),
            height: Int32(min(Double(maximumHeight), Double(reportedRenderSize.height) * scale)
                .rounded())
        )
    }

    /// The window animates into place, reporting a stream of sizes that differ
    /// by a pixel. Each one would otherwise cost a full screenshot.
    static func isSignificantChange(
        from current: CMVideoDimensions,
        to next: CMVideoDimensions
    ) -> Bool {
        guard next.width > 0, next.height > 0 else { return false }
        guard current.width > 0, current.height > 0 else { return true }
        let widthRatio = Double(next.width) / Double(current.width)
        let heightRatio = Double(next.height) / Double(current.height)
        return abs(widthRatio - 1) > significantChangeRatio
            || abs(heightRatio - 1) > significantChangeRatio
    }
}

/// Serially used from the MPV queue, where the raw screenshot lives. The pool
/// avoids allocating a new IOSurface for every screenshot while retaining its
/// BGRA layout.
final class MPVPictureInPictureFrameConverter: @unchecked Sendable {
    private var pixelBufferPool: CVPixelBufferPool?
    private var pooledSize = CMVideoDimensions(width: 0, height: 0)
    private let subtitleOverlay = MPVPictureInPictureSubtitleOverlay()

    func makeCapture(
        from frame: MPVPictureInPictureRawFrame,
        renderSize: CMVideoDimensions,
        screenshotDuration: TimeInterval
    ) -> MPVPictureInPictureCapture? {
        let startedAt = CACurrentMediaTime()
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4,
              frame.byteCount >= frame.stride * frame.height
        else { return nil }
        let outputSize = outputDimensions(for: frame, renderSize: renderSize)
        guard let pixelBuffer = makePixelBuffer(
            width: outputSize.width,
            height: outputSize.height
        ) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard Self.copyPixels(
            source: frame.pixels,
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            sourceStride: frame.stride,
            destination: destination,
            destinationWidth: outputSize.width,
            destinationHeight: outputSize.height,
            destinationStride: destinationStride
        ) else { return nil }
        // `bgr0` screenshots leave the alpha byte at zero. The Picture in
        // Picture window composites the sample buffer, so it must be opaque.
        Self.makeOpaque(
            destination,
            width: outputSize.width,
            height: outputSize.height,
            stride: destinationStride
        )
        var subtitleLayout: MPVPictureInPictureSubtitleLayout?
        if let subtitleText = frame.subtitleText {
            subtitleOverlay.draw(
                text: subtitleText,
                style: frame.subtitleStyle,
                in: pixelBuffer
            )
            subtitleLayout = MPVPictureInPictureSubtitleLayout(
                style: frame.subtitleStyle,
                frameWidth: outputSize.width,
                frameHeight: outputSize.height
            )
        }

        guard let sampleBuffer = Self.makeSampleBuffer(
            pixelBuffer: pixelBuffer,
            presentationTime: frame.presentationTime,
            videoFrameRate: frame.videoFrameRate
        ) else { return nil }
        return MPVPictureInPictureCapture(
            sampleBuffer: sampleBuffer,
            presentationTime: frame.presentationTime,
            videoFrameRate: frame.videoFrameRate,
            sourceWidth: frame.width,
            sourceHeight: frame.height,
            outputWidth: outputSize.width,
            outputHeight: outputSize.height,
            hasSubtitleOverlay: subtitleLayout != nil,
            subtitleLayout: subtitleLayout,
            screenshotDuration: screenshotDuration,
            conversionDuration: CACurrentMediaTime() - startedAt
        )
    }

    private static func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        presentationTime: TimeInterval,
        videoFrameRate: Double
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: sampleDuration(videoFrameRate: videoFrameRate),
            presentationTimeStamp: CMTime(
                seconds: presentationTime,
                preferredTimescale: 600
            ),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    static func sampleDuration(videoFrameRate: Double) -> CMTime {
        guard videoFrameRate.isFinite, videoFrameRate > 0 else {
            return CMTime(value: 1, timescale: 25)
        }
        let timescale = min(240, max(1, videoFrameRate.rounded()))
        return CMTime(value: 1, timescale: CMTimeScale(timescale))
    }

    private static func copyPixels(
        source: UnsafeRawPointer,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceStride: Int,
        destination: UnsafeMutableRawPointer,
        destinationWidth: Int,
        destinationHeight: Int,
        destinationStride: Int
    ) -> Bool {
        var sourceBuffer = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: source),
            height: vImagePixelCount(sourceHeight),
            width: vImagePixelCount(sourceWidth),
            rowBytes: sourceStride
        )
        var destinationBuffer = vImage_Buffer(
            data: destination,
            height: vImagePixelCount(destinationHeight),
            width: vImagePixelCount(destinationWidth),
            rowBytes: destinationStride
        )
        guard sourceWidth != destinationWidth || sourceHeight != destinationHeight else {
            return vImageCopyBuffer(
                &sourceBuffer,
                &destinationBuffer,
                4,
                vImage_Flags(kvImageDoNotTile)
            ) == kvImageNoError
        }
        // Accelerate resampling keeps downscaled Picture in Picture frames as
        // sharp as the inline player instead of dropping whole pixels.
        return vImageScale_ARGB8888(
            &sourceBuffer,
            &destinationBuffer,
            nil,
            vImage_Flags(kvImageHighQualityResampling | kvImageDoNotTile)
        ) == kvImageNoError
    }

    private static func makeOpaque(
        _ destination: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        stride: Int
    ) {
        var buffer = vImage_Buffer(
            data: destination,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: stride
        )
        // 32BGRA stores alpha in the last of the four interleaved channels.
        // The operation is done in place, so source and destination match.
        vImageOverwriteChannelsWithScalar_ARGB8888(
            .max,
            &buffer,
            &buffer,
            0x1,
            vImage_Flags(kvImageDoNotTile)
        )
    }

    private func outputDimensions(
        for frame: MPVPictureInPictureRawFrame,
        renderSize: CMVideoDimensions
    ) -> (width: Int, height: Int) {
        guard renderSize.width > 0, renderSize.height > 0 else {
            return (frame.width, frame.height)
        }
        let widthScale = Double(renderSize.width) / Double(frame.width)
        let heightScale = Double(renderSize.height) / Double(frame.height)
        let scale = min(1, widthScale, heightScale)
        return (
            max(1, Int((Double(frame.width) * scale).rounded(.down))),
            max(1, Int((Double(frame.height) * scale).rounded(.down)))
        )
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let requestedSize = CMVideoDimensions(width: Int32(width), height: Int32(height))
        if pixelBufferPool == nil
            || pooledSize.width != requestedSize.width
            || pooledSize.height != requestedSize.height
        {
            pooledSize = requestedSize
            pixelBufferPool = makePixelBufferPool(width: width, height: height)
        }
        guard let pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
            == kCVReturnSuccess
        else { return nil }
        return pixelBuffer
    }

    private func makePixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let poolAttributes: CFDictionary = [
            kCVPixelBufferPoolMinimumBufferCountKey: 2,
        ] as CFDictionary
        let pixelBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes,
            pixelBufferAttributes,
            &pool
        ) == kCVReturnSuccess else { return nil }
        return pool
    }
}
