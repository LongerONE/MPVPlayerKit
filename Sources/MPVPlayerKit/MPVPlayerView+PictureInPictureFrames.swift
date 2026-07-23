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

    func makeSampleBuffer() -> CMSampleBuffer? {
        guard width > 0, height > 0, stride >= width * 4 else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerRow = min(width * 4, min(stride, destinationStride))
        pixels.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destination.advanced(by: row * destinationStride),
                    sourceBase.advanced(by: row * stride),
                    bytesPerRow
                )
            }
        }

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 10),
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
        ) == noErr, let sampleBuffer else {
            return nil
        }
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
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately)
                    .toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
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
    nonisolated func capturePictureInPictureFrame(
        completion: @escaping @Sendable (MPVPictureInPictureFrame?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv else {
                completion(nil)
                return
            }

            var cargs = self.makeCArgs("screenshot-raw", ["window"]).map {
                $0.flatMap { UnsafePointer<CChar>(strdup($0)) }
            }
            defer {
                for pointer in cargs where pointer != nil {
                    free(UnsafeMutablePointer(mutating: pointer!))
                }
            }

            var result = mpv_node()
            let status = mpv_command_ret(mpv, &cargs, &result)
            guard status >= 0 else {
                self.checkError(
                    status,
                    operation: "picture-in-picture screenshot",
                    notifyOnFailure: false
                )
                completion(nil)
                return
            }
            defer { mpv_free_node_contents(&result) }
            guard let rawFrame = Self.pictureInPictureRawFrame(from: result),
                  rawFrame.format == "bgr0" || rawFrame.format == "bgra" else {
                completion(nil)
                return
            }
            completion(MPVPictureInPictureFrame(
                width: rawFrame.width,
                height: rawFrame.height,
                stride: rawFrame.stride,
                pixels: rawFrame.pixels,
                presentationTime: max(0, self.getDouble(MPVProperty.timePosition))
            ))
        }
    }

    private nonisolated static func pictureInPictureRawFrame(
        from result: mpv_node
    ) -> MPVPictureInPictureRawFrame? {
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list else {
            return nil
        }
        var frame = MPVPictureInPictureRawFrame()
        for index in 0..<Int(list.pointee.num) {
            guard let keyPointer = list.pointee.keys[index] else { continue }
            let key = String(cString: keyPointer)
            let value = list.pointee.values[index]
            switch key {
            case "w":
                if value.format == MPV_FORMAT_INT64 {
                    frame.width = Int(value.u.int64)
                }
            case "h":
                if value.format == MPV_FORMAT_INT64 {
                    frame.height = Int(value.u.int64)
                }
            case "stride":
                if value.format == MPV_FORMAT_INT64 {
                    frame.stride = Int(value.u.int64)
                }
            case "format":
                if value.format == MPV_FORMAT_STRING, let string = value.u.string {
                    frame.format = String(cString: string)
                }
            case "data":
                if value.format == MPV_FORMAT_BYTE_ARRAY, let byteArray = value.u.ba,
                   let data = byteArray.pointee.data {
                    frame.pixels = Data(
                        bytes: data,
                        count: byteArray.pointee.size
                    )
                }
            default:
                break
            }
        }
        guard frame.width > 0,
              frame.height > 0,
              frame.stride >= frame.width * 4,
              frame.pixels.count >= frame.stride * frame.height else {
            return nil
        }
        return frame
    }
}
