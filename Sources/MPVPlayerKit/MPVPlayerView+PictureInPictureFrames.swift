import AVFoundation
import CoreMedia
import CoreVideo
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

struct MPVPictureInPictureFrame: @unchecked Sendable {
    let width: Int
    let height: Int
    let stride: Int
    let pixels: Data
    let presentationTime: TimeInterval
}

/// Serially used by the PiP frame queue. The pool avoids allocating a new
/// IOSurface for every raw MPV screenshot while retaining its BGRA layout.
final class MPVPictureInPictureFrameConverter: @unchecked Sendable {
    private var pixelBufferPool: CVPixelBufferPool?
    private var pooledSize = CMVideoDimensions(width: 0, height: 0)

    func makeSampleBuffer(
        from frame: MPVPictureInPictureFrame,
        renderSize: CMVideoDimensions
    ) -> CMSampleBuffer? {
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4,
              frame.pixels.count >= frame.stride * frame.height
        else { return nil }
        let outputSize = outputDimensions(for: frame, renderSize: renderSize)
        guard let pixelBuffer = makePixelBuffer(width: outputSize.width, height: outputSize.height) else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let copiedBytes = min(outputSize.width * 4, destinationStride)
        frame.pixels.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            guard outputSize.width != frame.width || outputSize.height != frame.height else {
                for row in 0..<frame.height {
                    memcpy(
                        destination.advanced(by: row * destinationStride),
                        sourceBase.advanced(by: row * frame.stride),
                        copiedBytes
                    )
                }
                return
            }
            for row in 0..<outputSize.height {
                let sourceRow = min(frame.height - 1, row * frame.height / outputSize.height)
                let destinationRow = destination.advanced(by: row * destinationStride)
                let sourceRowAddress = sourceBase.advanced(by: sourceRow * frame.stride)
                for column in 0..<outputSize.width {
                    let sourceColumn = min(frame.width - 1, column * frame.width / outputSize.width)
                    memcpy(
                        destinationRow.advanced(by: column * 4),
                        sourceRowAddress.advanced(by: sourceColumn * 4),
                        4
                    )
                }
            }
        }
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMTime(seconds: frame.presentationTime, preferredTimescale: 600),
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

private struct MPVPictureInPictureRawFrame {
    var width = 0
    var height = 0
    var stride = 0
    var format = ""
    var pixels = Data()
}

extension MPVPlayerView {
    /// `video` is supported by current libmpv builds. Older bundled builds
    /// accept the command without the pixel format, so retain it as a fallback.
    nonisolated static let pictureInPictureScreenshotArgumentCandidates = [
        ["video", "bgra"],
        ["video"],
    ]

    nonisolated func capturePictureInPictureFrame(
        completion: @escaping @Sendable (MPVPictureInPictureFrame?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv else { completion(nil); return }
            var lastStatus = MPV_ERROR_INVALID_PARAMETER.rawValue
            for arguments in Self.pictureInPictureScreenshotArgumentCandidates {
                let capture = self.pictureInPictureScreenshot(
                    handle: mpv,
                    arguments: arguments
                )
                lastStatus = capture.status
                guard capture.status >= 0 else {
                    if capture.status == MPV_ERROR_INVALID_PARAMETER.rawValue { continue }
                    break
                }
                guard let rawFrame = capture.frame else { continue }
                completion(MPVPictureInPictureFrame(
                    width: rawFrame.width,
                    height: rawFrame.height,
                    stride: rawFrame.stride,
                    pixels: rawFrame.pixels,
                    presentationTime: max(0, self.getDouble(MPVProperty.timePosition))
                ))
                return
            }
            self.checkError(
                lastStatus,
                operation: "picture-in-picture screenshot",
                notifyOnFailure: false
            )
            self.mpvDebugLog("pip capture failed status=\(lastStatus)")
            completion(nil)
        }
    }

    private nonisolated func pictureInPictureScreenshot(
        handle: OpaquePointer,
        arguments: [String]
    ) -> (status: Int32, frame: MPVPictureInPictureRawFrame?) {
        var cargs = makeCArgs("screenshot-raw", arguments).map {
            $0.flatMap { UnsafePointer<CChar>(strdup($0)) }
        }
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }
        var result = mpv_node()
        let status = mpv_command_ret(handle, &cargs, &result)
        guard status >= 0 else { return (status, nil) }
        defer { mpv_free_node_contents(&result) }
        guard let frame = Self.pictureInPictureRawFrame(from: result),
              frame.format == "bgr0" || frame.format == "bgra"
        else { return (status, nil) }
        return (status, frame)
    }

    private nonisolated static func pictureInPictureRawFrame(
        from result: mpv_node
    ) -> MPVPictureInPictureRawFrame? {
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list else { return nil }
        var frame = MPVPictureInPictureRawFrame()
        for index in 0..<Int(list.pointee.num) {
            guard let keyPointer = list.pointee.keys[index] else { continue }
            let value = list.pointee.values[index]
            switch String(cString: keyPointer) {
            case "w" where value.format == MPV_FORMAT_INT64: frame.width = Int(value.u.int64)
            case "h" where value.format == MPV_FORMAT_INT64: frame.height = Int(value.u.int64)
            case "stride" where value.format == MPV_FORMAT_INT64: frame.stride = Int(value.u.int64)
            case "format" where value.format == MPV_FORMAT_STRING:
                guard let format = value.u.string else { continue }
                frame.format = String(cString: format)
            case "data" where value.format == MPV_FORMAT_BYTE_ARRAY:
                guard let bytes = value.u.ba, let data = bytes.pointee.data else { continue }
                frame.pixels = Data(bytes: data, count: bytes.pointee.size)
            default: break
            }
        }
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4,
              frame.pixels.count >= frame.stride * frame.height
        else { return nil }
        return frame
    }
}
