import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

private struct MPVPictureInPictureRawFrameDescriptor {
    var width = 0
    var height = 0
    var stride = 0
    var format = ""
    var pixels: UnsafeRawPointer?
    var byteCount = 0
}

extension MPVPlayerView {
    /// `bgra` is supported by current libmpv builds. Older bundled builds
    /// accept the command without the pixel format, so retain it as a fallback.
    nonisolated static func pictureInPictureScreenshotArgumentCandidates(
        for mode: MPVPictureInPictureCaptureMode
    ) -> [[String]] {
        switch mode {
        case .videoWithSubtitleOverlay:
            [["video", "bgra"], ["video"]]
        case .window:
            [["window", "bgra"], ["window"]]
        }
    }

    /// Captures one frame and converts it on the MPV queue.
    ///
    /// The screenshot pixels are converted while libmpv still owns them, so a
    /// 4K frame is never copied into an intermediate buffer just to be scaled
    /// down to the size of the Picture in Picture window.
    nonisolated func capturePictureInPictureFrame(
        renderSize: CMVideoDimensions,
        converter: MPVPictureInPictureFrameConverter,
        completion: @escaping @Sendable (MPVPictureInPictureCapture?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv else { completion(nil); return }
            let mode = self.pictureInPictureCaptureMode
            var lastStatus = MPV_ERROR_INVALID_PARAMETER.rawValue
            for arguments in Self.pictureInPictureScreenshotArgumentCandidates(for: mode) {
                let capture = self.pictureInPictureScreenshot(
                    handle: mpv,
                    arguments: arguments,
                    mode: mode,
                    renderSize: renderSize,
                    converter: converter
                )
                lastStatus = capture.status
                guard capture.status >= 0 else {
                    if capture.status == MPV_ERROR_INVALID_PARAMETER.rawValue { continue }
                    break
                }
                guard let frame = capture.capture else { continue }
                completion(frame)
                return
            }
            self.checkError(
                lastStatus,
                operation: "picture-in-picture screenshot",
                notifyOnFailure: false
            )
            self.mpvDebugLog("pip capture failed mode=\(mode) status=\(lastStatus)")
            completion(nil)
        }
    }

    /// Read on the MPV queue while capturing a frame.
    private nonisolated func pictureInPictureVideoFrameRate() -> Double {
        let estimated = getDouble(MPVProperty.estimatedVideoFilterFPS)
        if estimated.isFinite, estimated > 0 { return estimated }
        let container = getDouble(MPVProperty.containerFPS)
        return container.isFinite && container > 0 ? container : 0
    }

    /// The inline player shows MPV-rendered subtitles. Capture the same text so
    /// the Picture in Picture overlay can draw it, and only while MPV would
    /// render it, so hidden subtitles stay hidden in both places. Window
    /// captures already contain MPV's own subtitles.
    private nonisolated func pictureInPictureSubtitleText(
        mode: MPVPictureInPictureCaptureMode
    ) -> String? {
        guard mode == .videoWithSubtitleOverlay else {
            logPictureInPictureSubtitleState("mpv-rendered")
            return nil
        }
        guard pictureInPictureSubtitleOverlayEnabled else {
            logPictureInPictureSubtitleState("overlay-disabled")
            return nil
        }
        guard getFlag(MPVProperty.subtitleVisibility) == true else {
            logPictureInPictureSubtitleState(
                "hidden sid=\(getInt64(MPVProperty.subtitleID).map(String.init) ?? "none")"
            )
            return nil
        }
        let normalized = getString(MPVProperty.subtitleText)
            .map(MPVPictureInPictureSubtitleOverlay.normalizedText) ?? ""
        guard normalized.isEmpty == false else {
            logPictureInPictureSubtitleState(
                "no-text sid=\(getInt64(MPVProperty.subtitleID).map(String.init) ?? "none")"
            )
            return nil
        }
        logPictureInPictureSubtitleState("text chars=\(normalized.count)")
        return normalized
    }

    private nonisolated func logPictureInPictureSubtitleState(_ state: String) {
        #if DEBUG
        guard lastPictureInPictureSubtitleState != state else { return }
        lastPictureInPictureSubtitleState = state
        mpvDebugLog("pip subtitle capture \(state)")
        #endif
    }

    /// MPV reports the video rectangle inside its window as OSD margins.
    private nonisolated func pictureInPictureWindowCrop(
        frameWidth: Int,
        frameHeight: Int
    ) -> MPVPictureInPictureCropRect {
        MPVPictureInPictureWindowCrop.resolve(
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            left: Int(getInt64(MPVProperty.osdMarginLeft) ?? 0),
            top: Int(getInt64(MPVProperty.osdMarginTop) ?? 0),
            right: Int(getInt64(MPVProperty.osdMarginRight) ?? 0),
            bottom: Int(getInt64(MPVProperty.osdMarginBottom) ?? 0)
        )
    }

    private nonisolated func pictureInPictureScreenshot(
        handle: OpaquePointer,
        arguments: [String],
        mode: MPVPictureInPictureCaptureMode,
        renderSize: CMVideoDimensions,
        converter: MPVPictureInPictureFrameConverter
    ) -> (status: Int32, capture: MPVPictureInPictureCapture?) {
        var cargs = makeCArgs("screenshot-raw", arguments).map {
            $0.flatMap { UnsafePointer<CChar>(strdup($0)) }
        }
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer!))
            }
        }
        var result = mpv_node()
        let startedAt = CACurrentMediaTime()
        let status = mpv_command_ret(handle, &cargs, &result)
        guard status >= 0 else { return (status, nil) }
        defer { mpv_free_node_contents(&result) }
        let screenshotDuration = CACurrentMediaTime() - startedAt
        guard let descriptor = Self.pictureInPictureRawFrameDescriptor(from: result),
              descriptor.format == "bgr0" || descriptor.format == "bgra",
              let pixels = descriptor.pixels
        else { return (status, nil) }
        let crop = mode == .window
            ? pictureInPictureWindowCrop(
                frameWidth: descriptor.width,
                frameHeight: descriptor.height
            )
            : MPVPictureInPictureCropRect.full(
                width: descriptor.width,
                height: descriptor.height
            )
        let frame = MPVPictureInPictureRawFrame(
            width: descriptor.width,
            height: descriptor.height,
            stride: descriptor.stride,
            pixels: pixels,
            byteCount: descriptor.byteCount,
            crop: crop,
            captureMode: mode,
            presentationTime: max(0, getDouble(MPVProperty.timePosition)),
            videoFrameRate: pictureInPictureVideoFrameRate(),
            subtitleText: pictureInPictureSubtitleText(mode: mode),
            subtitleStyle: MPVPictureInPictureSubtitleStyle(
                propertyValues: subtitleStyleValues
            )
        )
        return (
            status,
            converter.makeCapture(
                from: frame,
                renderSize: renderSize,
                screenshotDuration: screenshotDuration
            )
        )
    }

    private nonisolated static func pictureInPictureRawFrameDescriptor(
        from result: mpv_node
    ) -> MPVPictureInPictureRawFrameDescriptor? {
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list else { return nil }
        var frame = MPVPictureInPictureRawFrameDescriptor()
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
                frame.pixels = UnsafeRawPointer(data)
                frame.byteCount = bytes.pointee.size
            default: break
            }
        }
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4,
              frame.byteCount >= frame.stride * frame.height
        else { return nil }
        return frame
    }
}
