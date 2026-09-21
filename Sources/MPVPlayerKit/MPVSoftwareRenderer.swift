#if targetEnvironment(simulator)
import CoreGraphics
import Foundation
import QuartzCore
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

final class MPVSoftwareRenderCallbackContext: @unchecked Sendable {
    weak var renderer: MPVSoftwareRenderer?
}

/// 模拟器完全避开 Metal/MoltenVK，只把 libmpv 的 CPU 帧交给 CALayer 显示。
final class MPVSoftwareRenderer: @unchecked Sendable {
    private static let width = 960
    private static let height = 540
    private static let bytesPerPixel = 4

    private weak var playerView: MPVPlayerView?
    private let renderQueue = DispatchQueue(
        label: "com.mpvplayerkit.software-renderer",
        qos: .userInitiated
    )
    private var renderContext: OpaquePointer?
    private var callbackContext: Unmanaged<MPVSoftwareRenderCallbackContext>?
    private var pixelBuffer: UnsafeMutableRawPointer?
    private var pixelBufferSize = 0
    private var stopped = false

    init?(mpv: OpaquePointer, playerView: MPVPlayerView) {
        self.playerView = playerView

        var context: OpaquePointer?
        let api = UnsafeMutableRawPointer(
            mutating: (MPV_RENDER_API_TYPE_SW as NSString).utf8String
        )
        var params = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
            mpv_render_param(),
        ]
        guard mpv_render_context_create(&context, mpv, &params) >= 0,
              let context else {
            return nil
        }

        renderContext = context
        let callback = MPVSoftwareRenderCallbackContext()
        let callbackTransfer = Unmanaged.passRetained(callback)
        callbackContext = callbackTransfer
        callback.renderer = self
        mpv_render_context_set_update_callback(
            context,
            mpvSoftwareRenderUpdateCallback,
            callbackTransfer.toOpaque()
        )
    }

    deinit {
        stop()
        pixelBuffer?.deallocate()
    }

    func stop() {
        renderQueue.sync {
            guard stopped == false else { return }
            stopped = true
            if let renderContext {
                mpv_render_context_set_update_callback(renderContext, nil, nil)
                mpv_render_context_free(renderContext)
                self.renderContext = nil
            }
            callbackContext?.release()
            callbackContext = nil
        }
    }

    fileprivate func scheduleRender() {
        renderQueue.async { [weak self] in
            self?.renderFrameIfNeeded()
        }
    }

    private func renderFrameIfNeeded() {
        dispatchPrecondition(condition: .onQueue(renderQueue))
        guard stopped == false, let renderContext else { return }
        let flags = mpv_render_context_update(renderContext)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0,
              let pixelBuffer = ensurePixelBuffer() else {
            return
        }

        var size = [CInt(Self.width), CInt(Self.height)]
        var format = Array("rgb0".utf8CString)
        var stride = UInt(Self.width * Self.bytesPerPixel)
        let status = size.withUnsafeMutableBufferPointer { sizePointer in
            format.withUnsafeMutableBufferPointer { formatPointer in
                withUnsafeMutablePointer(to: &stride) { stridePointer in
                    var params = [
                        mpv_render_param(
                            type: MPV_RENDER_PARAM_SW_SIZE,
                            data: UnsafeMutableRawPointer(sizePointer.baseAddress!)
                        ),
                        mpv_render_param(
                            type: MPV_RENDER_PARAM_SW_FORMAT,
                            data: UnsafeMutableRawPointer(formatPointer.baseAddress!)
                        ),
                        mpv_render_param(
                            type: MPV_RENDER_PARAM_SW_STRIDE,
                            data: UnsafeMutableRawPointer(stridePointer)
                        ),
                        mpv_render_param(
                            type: MPV_RENDER_PARAM_SW_POINTER,
                            data: pixelBuffer
                        ),
                        mpv_render_param(),
                    ]
                    return mpv_render_context_render(renderContext, &params)
                }
            }
        }
        guard status >= 0 else {
            playerView?.mpvDebugLog("software render failed status=\(status)")
            return
        }

        let frameData = Data(bytes: pixelBuffer, count: pixelBufferSize)
        guard let provider = CGDataProvider(data: frameData as CFData),
              let image = CGImage(
                  width: Self.width,
                  height: Self.height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: Int(stride),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                          | CGImageAlphaInfo.noneSkipLast.rawValue
                  ),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return
        }
        playerView?.publishSoftwareFrame(image)
    }

    private func ensurePixelBuffer() -> UnsafeMutableRawPointer? {
        guard pixelBuffer == nil else { return pixelBuffer }
        pixelBufferSize = Self.width * Self.height * Self.bytesPerPixel
        pixelBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: pixelBufferSize,
            alignment: 64
        )
        return pixelBuffer
    }
}

private func mpvSoftwareRenderUpdateCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let callback = Unmanaged<MPVSoftwareRenderCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    callback.renderer?.scheduleRender()
}
#endif
