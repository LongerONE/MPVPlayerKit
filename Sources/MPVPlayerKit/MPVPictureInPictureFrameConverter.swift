import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo

/// One raw MPV screenshot plus the playback context needed to present it in the
/// Picture in Picture window.
struct MPVPictureInPictureFrame: @unchecked Sendable {
    let width: Int
    let height: Int
    let stride: Int
    let pixels: Data
    let presentationTime: TimeInterval
    let videoFrameRate: Double
    let subtitleText: String?
    let subtitleStyle: MPVPictureInPictureSubtitleStyle

    init(
        width: Int,
        height: Int,
        stride: Int,
        pixels: Data,
        presentationTime: TimeInterval,
        videoFrameRate: Double = 0,
        subtitleText: String? = nil,
        subtitleStyle: MPVPictureInPictureSubtitleStyle = MPVPictureInPictureSubtitleStyle()
    ) {
        self.width = width
        self.height = height
        self.stride = stride
        self.pixels = pixels
        self.presentationTime = presentationTime
        self.videoFrameRate = videoFrameRate
        self.subtitleText = subtitleText
        self.subtitleStyle = subtitleStyle
    }
}

/// Serially used by the PiP frame queue. The pool avoids allocating a new
/// IOSurface for every raw MPV screenshot while retaining its BGRA layout.
final class MPVPictureInPictureFrameConverter: @unchecked Sendable {
    private var pixelBufferPool: CVPixelBufferPool?
    private var pooledSize = CMVideoDimensions(width: 0, height: 0)
    private let subtitleOverlay = MPVPictureInPictureSubtitleOverlay()

    func makeSampleBuffer(
        from frame: MPVPictureInPictureFrame,
        renderSize: CMVideoDimensions
    ) -> CMSampleBuffer? {
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4,
              frame.pixels.count >= frame.stride * frame.height
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
        let scaled = frame.pixels.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return false }
            return Self.copyPixels(
                source: sourceBase,
                sourceWidth: frame.width,
                sourceHeight: frame.height,
                sourceStride: frame.stride,
                destination: destination,
                destinationWidth: outputSize.width,
                destinationHeight: outputSize.height,
                destinationStride: destinationStride
            )
        }
        guard scaled else { return nil }
        // `bgr0` screenshots leave the alpha byte at zero. The Picture in
        // Picture window composites the sample buffer, so it must be opaque.
        Self.makeOpaque(
            destination,
            width: outputSize.width,
            height: outputSize.height,
            stride: destinationStride
        )
        if let subtitleText = frame.subtitleText {
            subtitleOverlay.draw(
                text: subtitleText,
                style: frame.subtitleStyle,
                in: pixelBuffer
            )
        }

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: Self.sampleDuration(videoFrameRate: frame.videoFrameRate),
            presentationTimeStamp: CMTime(
                seconds: frame.presentationTime,
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
        for frame: MPVPictureInPictureFrame,
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
