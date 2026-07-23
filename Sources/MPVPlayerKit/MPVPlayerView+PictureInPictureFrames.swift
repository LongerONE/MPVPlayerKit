import AVFoundation
import CoreMedia
import CoreText
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
    let subtitleText: String?

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
                let destinationRow = destination.advanced(by: row * destinationStride)
                memcpy(
                    destinationRow,
                    sourceBase.advanced(by: row * stride),
                    bytesPerRow
                )
                for pixel in 0..<width {
                    destinationRow.storeBytes(
                        of: UInt8.max,
                        toByteOffset: pixel * 4 + 3,
                        as: UInt8.self
                    )
                }
            }
        }
        drawSubtitle(in: pixelBuffer)

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

    private func drawSubtitle(in pixelBuffer: CVPixelBuffer) {
        guard let subtitleText,
              subtitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                      | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return
        }

        let fontSize = min(max(CGFloat(height) * 0.065, 16), 52)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        var alignment = CTTextAlignment.center
        let paragraphStyle = withUnsafePointer(to: &alignment) { alignmentPointer in
            let paragraphSettings = [
                CTParagraphStyleSetting(
                    spec: .alignment,
                    valueSize: MemoryLayout<CTTextAlignment>.size,
                    value: UnsafeRawPointer(alignmentPointer)
                ),
            ]
            return CTParagraphStyleCreate(
                paragraphSettings,
                paragraphSettings.count
            )
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 1, alpha: 1),
            NSAttributedString.Key(kCTStrokeColorAttributeName as String):
                CGColor(gray: 0, alpha: 1),
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -3,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String):
                paragraphStyle,
        ]
        let attributedText = NSAttributedString(
            string: subtitleText,
            attributes: attributes
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let maximumWidth = CGFloat(width) * 0.9
        let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(),
            nil,
            CGSize(width: maximumWidth, height: CGFloat(height) * 0.35),
            nil
        )
        let textRect = CGRect(
            x: (CGFloat(width) - maximumWidth) / 2,
            y: max(CGFloat(height) * 0.08, 12),
            width: maximumWidth,
            height: ceil(suggestedSize.height)
        )
        let path = CGPath(rect: textRect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        CTFrameDraw(frame, context)
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
    nonisolated static let pictureInPictureScreenshotArgumentCandidates = [
        ["video", "bgra"],
        ["video"],
    ]

    nonisolated static func isPictureInPictureFrameCaptureReady(
        hasPlaybackRestarted: Bool
    ) -> Bool {
        hasPlaybackRestarted
    }

    nonisolated func capturePictureInPictureFrame(
        completion: @escaping @Sendable (MPVPictureInPictureFrame?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion(nil)
                return
            }

            self.pictureInPictureCaptureSequence &+= 1
            let sequence = self.pictureInPictureCaptureSequence
            let shouldLog = sequence <= 10 || sequence.isMultiple(of: 30)
            let isReady = Self.isPictureInPictureFrameCaptureReady(
                hasPlaybackRestarted: self.hasPlaybackRestarted
            )
            if shouldLog {
                self.mpvDebugLog(
                    "pip capture stage=begin sequence=\(sequence) "
                        + "ready=\(isReady) hasHandle=\(self.mpv != nil)"
                )
            }
            guard isReady, let mpv = self.mpv else {
                if shouldLog {
                    self.mpvDebugLog(
                        "pip capture stage=skipped sequence=\(sequence)"
                    )
                }
                completion(nil)
                return
            }

            var lastStatus = MPV_ERROR_INVALID_PARAMETER.rawValue
            for arguments in Self.pictureInPictureScreenshotArgumentCandidates {
                let capture = self.pictureInPictureScreenshot(
                    handle: mpv,
                    arguments: arguments,
                    sequence: sequence,
                    shouldLog: shouldLog
                )
                lastStatus = capture.status
                guard capture.status >= 0 else {
                    if capture.status == MPV_ERROR_INVALID_PARAMETER.rawValue {
                        continue
                    }
                    break
                }
                guard let rawFrame = capture.frame else { continue }
                self.pictureInPictureScreenshotErrorCount = 0
                if shouldLog {
                    self.mpvDebugLog(
                        "pip capture stage=success sequence=\(sequence) "
                            + "width=\(rawFrame.width) height=\(rawFrame.height) "
                            + "stride=\(rawFrame.stride) bytes=\(rawFrame.pixels.count)"
                    )
                }
                completion(MPVPictureInPictureFrame(
                    width: rawFrame.width,
                    height: rawFrame.height,
                    stride: rawFrame.stride,
                    pixels: rawFrame.pixels,
                    presentationTime: max(0, self.getDouble(MPVProperty.timePosition)),
                    subtitleText: self.getString(MPVProperty.subtitleText)
                ))
                return
            }

            if self.pictureInPictureScreenshotErrorCount == 0 {
                self.checkError(
                    lastStatus,
                    operation: "picture-in-picture screenshot",
                    notifyOnFailure: false
                )
            }
            self.pictureInPictureScreenshotErrorCount += 1
            if shouldLog {
                self.mpvDebugLog(
                    "pip capture stage=failed sequence=\(sequence) status=\(lastStatus)"
                )
            }
            completion(nil)
        }
    }

    private nonisolated func pictureInPictureScreenshot(
        handle: OpaquePointer,
        arguments: [String],
        sequence: UInt64,
        shouldLog: Bool
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
        let commandStart = ProcessInfo.processInfo.systemUptime
        if shouldLog {
            mpvDebugLog(
                "pip screenshot stage=command-begin sequence=\(sequence) "
                    + "arguments=\(arguments.joined(separator: ","))"
            )
        }
        let status = mpv_command_ret(handle, &cargs, &result)
        let commandDuration = String(
            format: "%.3f",
            (ProcessInfo.processInfo.systemUptime - commandStart) * 1_000
        )
        if shouldLog {
            mpvDebugLog(
                "pip screenshot stage=command-end sequence=\(sequence) "
                    + "status=\(status) durationMs=\(commandDuration)"
            )
        }
        guard status >= 0 else { return (status, nil) }

        let frame = Self.pictureInPictureRawFrame(from: result)
        if shouldLog {
            let description = frame.map {
                "format=\($0.format) width=\($0.width) height=\($0.height) "
                    + "stride=\($0.stride) bytes=\($0.pixels.count)"
            } ?? "frame=nil"
            mpvDebugLog(
                "pip screenshot stage=node-free-begin sequence=\(sequence) "
                    + description
            )
        }
        mpv_free_node_contents(&result)
        if shouldLog {
            mpvDebugLog("pip screenshot stage=node-free-end sequence=\(sequence)")
        }
        guard let frame,
              frame.format == "bgr0" || frame.format == "bgra" else {
            return (status, nil)
        }
        return (status, frame)
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
