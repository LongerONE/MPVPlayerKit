import QuartzCore

private struct MPVPlayerMetalLayerTransfer<Value>: @unchecked Sendable {
    let value: Value
}

final class MPVPlayerMetalLayer: CAMetalLayer, @unchecked Sendable {

    override var pixelFormat: MTLPixelFormat {
        get { super.pixelFormat }
        set {
            guard Thread.isMainThread == false else {
                super.pixelFormat = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.async {
                transfer.value.0.pixelFormat = transfer.value.1
            }
        }
    }

    override var maximumDrawableCount: Int {
        get { super.maximumDrawableCount }
        set {
            guard Thread.isMainThread == false else {
                super.maximumDrawableCount = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.async {
                transfer.value.0.maximumDrawableCount = transfer.value.1
            }
        }
    }

    override var minificationFilter: CALayerContentsFilter {
        get { super.minificationFilter }
        set {
            guard Thread.isMainThread == false else {
                super.minificationFilter = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.async {
                transfer.value.0.minificationFilter = transfer.value.1
            }
        }
    }

    override var magnificationFilter: CALayerContentsFilter {
        get { super.magnificationFilter }
        set {
            guard Thread.isMainThread == false else {
                super.magnificationFilter = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.async {
                transfer.value.0.magnificationFilter = transfer.value.1
            }
        }
    }

    override var contentsGravity: CALayerContentsGravity {
        get { super.contentsGravity }
        set {
            guard Thread.isMainThread == false else {
                super.contentsGravity = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.async {
                transfer.value.0.contentsGravity = transfer.value.1
            }
        }
    }

    override var framebufferOnly: Bool {
        get { super.framebufferOnly }
        set {
            guard Thread.isMainThread == false else {
                super.framebufferOnly = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.async {
                transfer.value.0.framebufferOnly = transfer.value.1
            }
        }
    }

    override var isOpaque: Bool {
        get { super.isOpaque }
        set {
            guard Thread.isMainThread == false else {
                super.isOpaque = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.async {
                transfer.value.0.isOpaque = transfer.value.1
            }
        }
    }

    override var colorspace: CGColorSpace? {
        get { super.colorspace }
        set {
            guard Thread.isMainThread == false else {
                super.colorspace = newValue
                return
            }
            let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
            DispatchQueue.main.async {
                transfer.value.0.colorspace = transfer.value.1
            }
        }
    }

    @available(iOS 16.0, tvOS 16.0, *)
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            guard Thread.isMainThread else {
                return
            }
            super.wantsExtendedDynamicRangeContent = newValue
        }
    }

    override var drawableSize: CGSize {
        get {
            super.drawableSize
        }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                guard Thread.isMainThread == false else {
                    super.drawableSize = newValue
                    return
                }
                let transfer = MPVPlayerMetalLayerTransfer(value: (self, newValue))
                DispatchQueue.main.async {
                    transfer.value.0.drawableSize = transfer.value.1
                }
            }
        }
    }

    override func setNeedsDisplay() {
        // MPV presents frames through Vulkan/MoltenVK. Calling
        // `setNeedsDisplay` from its `vo_thread` only creates a Core Animation
        // display invalidation and, on recent iOS versions, can commit an
        // Auto Layout transaction from that renderer thread. The Vulkan
        // present path does not need this invalidation, so drop background
        // calls and keep UIKit/Core Animation work on the main thread.
        guard Thread.isMainThread else {
            return
        }
        super.setNeedsDisplay()
    }

    override func setNeedsDisplay(_ rect: CGRect) {
        guard Thread.isMainThread else {
            return
        }
        super.setNeedsDisplay(rect)
    }
}
