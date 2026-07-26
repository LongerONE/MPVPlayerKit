import AVFoundation
import CoreMedia
import CoreVideo
import IOSurface
import Metal

/// Candidate storage formats for the phase-B final-frame bridge.
///
/// This intentionally probes allocation and Metal interoperability only. It
/// never changes the MPV renderer, its output format, or the active PiP frame
/// source.
enum MPVPictureInPicturePixelBufferFormat: String, CaseIterable, Sendable {
    case bgra8
    case yuv42010VideoRange
    case rgba16Float

    var coreVideoPixelFormat: OSType {
        switch self {
        case .bgra8: kCVPixelFormatType_32BGRA
        case .yuv42010VideoRange: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .rgba16Float: kCVPixelFormatType_64RGBAHalf
        }
    }

    var metalTextureFormat: MTLPixelFormat {
        switch self {
        case .bgra8: .bgra8Unorm
        case .yuv42010VideoRange: .r16Unorm
        case .rgba16Float: .rgba16Float
        }
    }
}

struct MPVPictureInPicturePixelBufferCapability: Equatable, Sendable {
    let format: MPVPictureInPicturePixelBufferFormat
    let resolvedAttributes: Bool
    let poolCreated: Bool
    let pixelBufferCreated: Bool
    let isIOSurfaceBacked: Bool
    let isMetalTextureCreatable: Bool
}

struct MPVPictureInPictureRendererPerformanceMetrics: Equatable, Sendable {
    let totalFrames: Int
    let droppedFrames: Int
    let corruptedFrames: Int
    let accumulatedFrameDelay: TimeInterval
}

struct MPVPictureInPictureRendererCapability: Equatable, Sendable {
    let isSampleBufferRendererAvailable: Bool
    let rendererStatus: String?
    let requiresFlushToResumeDecoding: Bool?
    let hasRecommendedPixelBufferAttributes: Bool
    let supportsPerformanceMetrics: Bool
    let pixelBufferCapabilities: [MPVPictureInPicturePixelBufferCapability]

    var diagnosticDescription: String {
        let status = rendererStatus ?? "unavailable"
        let requiresFlush = requiresFlushToResumeDecoding.map(String.init) ?? "unavailable"
        let formats = pixelBufferCapabilities.map { capability in
            "\(capability.format.rawValue):resolved=\(capability.resolvedAttributes) "
                + "pool=\(capability.poolCreated) buffer=\(capability.pixelBufferCreated) "
                + "iosurface=\(capability.isIOSurfaceBacked) "
                + "metal=\(capability.isMetalTextureCreatable)"
        }.joined(separator: ", ")
        return "pip capability renderer=\(isSampleBufferRendererAvailable) "
            + "status=\(status) "
            + "requiresFlush=\(requiresFlush) "
            + "recommendedAttributes=\(hasRecommendedPixelBufferAttributes) "
            + "performanceMetrics=\(supportsPerformanceMetrics) [\(formats)]"
    }
}

/// Internal, non-invasive diagnostics for the phase-B PiP frame bridge.
///
/// Apple documents `sampleBufferRenderer` as the path for background-thread
/// enqueueing (iOS 17+), and documents that recommended attributes must be
/// reconciled with `CVPixelBufferCreateResolvedAttributesDictionary` (iOS 26+).
/// - SeeAlso: https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/samplebufferrenderer
/// - SeeAlso: https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/recommendedpixelbufferattributes
@MainActor
final class MPVPictureInPictureCapabilityProbe {
    private static let probeWidth = 64
    private static let probeHeight = 64

    /// Merges system recommendations with the fixed requirements of one
    /// candidate. Candidate requirements intentionally win: this function is
    /// used to determine whether that exact format can be allocated.
    static func mergedPixelBufferAttributes(
        recommended: [String: Any],
        required: [String: Any]
    ) -> [String: Any] {
        recommended.merging(required, uniquingKeysWith: { _, requiredValue in requiredValue })
    }

    static func requiredPixelBufferAttributes(
        for format: MPVPictureInPicturePixelBufferFormat,
        width: Int = probeWidth,
        height: Int = probeHeight
    ) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: format.coreVideoPixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }

    func probe(displayLayer: AVSampleBufferDisplayLayer) -> MPVPictureInPictureRendererCapability {
        guard #available(iOS 17.0, *) else {
            return MPVPictureInPictureRendererCapability(
                isSampleBufferRendererAvailable: false,
                rendererStatus: nil,
                requiresFlushToResumeDecoding: nil,
                hasRecommendedPixelBufferAttributes: false,
                supportsPerformanceMetrics: false,
                pixelBufferCapabilities: []
            )
        }

        // `sampleBufferRenderer` is the actual renderer owned by this display
        // layer. Reading it has no effect on the layer's current frame source.
        let renderer = displayLayer.sampleBufferRenderer
        let recommendedAttributes: [String: Any]
        if #available(iOS 26.0, *) {
            recommendedAttributes = renderer.recommendedPixelBufferAttributes as? [String: Any] ?? [:]
        } else {
            recommendedAttributes = [:]
        }
        let capabilities = MPVPictureInPicturePixelBufferFormat.allCases.map {
            probePixelBuffer(format: $0, recommendedAttributes: recommendedAttributes)
        }
        return MPVPictureInPictureRendererCapability(
            isSampleBufferRendererAvailable: true,
            rendererStatus: String(describing: renderer.status),
            requiresFlushToResumeDecoding: renderer.requiresFlushToResumeDecoding,
            hasRecommendedPixelBufferAttributes: recommendedAttributes.isEmpty == false,
            supportsPerformanceMetrics: {
                if #available(iOS 17.4, *) { return true }
                return false
            }(),
            pixelBufferCapabilities: capabilities
        )
    }

    /// Reads the public iOS 17.4 performance snapshot without affecting sample
    /// delivery. The completion may receive `nil` before the renderer has
    /// presented a frame.
    /// - SeeAlso: https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/videoperformancemetrics()
    func loadPerformanceMetrics(
        from displayLayer: AVSampleBufferDisplayLayer,
        completion: @escaping @Sendable (MPVPictureInPictureRendererPerformanceMetrics?) -> Void
    ) {
        guard #available(iOS 17.4, *) else {
            completion(nil)
            return
        }
        displayLayer.sampleBufferRenderer.loadVideoPerformanceMetrics { metrics in
            guard let metrics else {
                completion(nil)
                return
            }
            completion(MPVPictureInPictureRendererPerformanceMetrics(
                totalFrames: metrics.totalNumberOfFrames,
                droppedFrames: metrics.numberOfDroppedFrames,
                corruptedFrames: metrics.numberOfCorruptedFrames,
                accumulatedFrameDelay: metrics.totalAccumulatedFrameDelay
            ))
        }
    }

    private func probePixelBuffer(
        format: MPVPictureInPicturePixelBufferFormat,
        recommendedAttributes: [String: Any]
    ) -> MPVPictureInPicturePixelBufferCapability {
        let requiredAttributes = Self.requiredPixelBufferAttributes(for: format)
        let mergedAttributes = Self.mergedPixelBufferAttributes(
            recommended: recommendedAttributes,
            required: requiredAttributes
        )
        let resolvedAttributes = resolvePixelBufferAttributes(
            recommendedAttributes: recommendedAttributes,
            mergedAttributes: mergedAttributes
        )
        let attributes = resolvedAttributes.attributes
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 4,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool
        else {
            return MPVPictureInPicturePixelBufferCapability(
                format: format,
                resolvedAttributes: resolvedAttributes.didResolve,
                poolCreated: false,
                pixelBufferCreated: false,
                isIOSurfaceBacked: false,
                isMetalTextureCreatable: false
            )
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            == kCVReturnSuccess, let pixelBuffer
        else {
            return MPVPictureInPicturePixelBufferCapability(
                format: format,
                resolvedAttributes: resolvedAttributes.didResolve,
                poolCreated: true,
                pixelBufferCreated: false,
                isIOSurfaceBacked: false,
                isMetalTextureCreatable: false
            )
        }
        return MPVPictureInPicturePixelBufferCapability(
            format: format,
            resolvedAttributes: resolvedAttributes.didResolve,
            poolCreated: true,
            pixelBufferCreated: true,
            isIOSurfaceBacked: CVPixelBufferGetIOSurface(pixelBuffer) != nil,
            isMetalTextureCreatable: canCreateMetalTexture(from: pixelBuffer, format: format)
        )
    }

    private func resolvePixelBufferAttributes(
        recommendedAttributes: [String: Any],
        mergedAttributes: [String: Any]
    ) -> (didResolve: Bool, attributes: [String: Any]) {
        var resolvedAttributes: CFDictionary?
        let sources: [CFDictionary]
        if recommendedAttributes.isEmpty {
            sources = [mergedAttributes as CFDictionary]
        } else {
            sources = [
                recommendedAttributes as CFDictionary,
                mergedAttributes as CFDictionary,
            ]
        }
        let result = CVPixelBufferCreateResolvedAttributesDictionary(
            kCFAllocatorDefault,
            sources as CFArray,
            &resolvedAttributes
        )
        guard result == kCVReturnSuccess,
              let resolvedAttributes,
              let attributes = resolvedAttributes as? [String: Any]
        else {
            return (false, mergedAttributes)
        }
        return (true, attributes)
    }

    private func canCreateMetalTexture(
        from pixelBuffer: CVPixelBuffer,
        format: MPVPictureInPicturePixelBufferFormat
    ) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        ) == kCVReturnSuccess, let textureCache
        else { return false }
        var texture: CVMetalTexture?
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let textureWidth = width > 0 ? width : CVPixelBufferGetWidth(pixelBuffer)
        let textureHeight = height > 0 ? height : CVPixelBufferGetHeight(pixelBuffer)
        return CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            format.metalTextureFormat,
            textureWidth,
            textureHeight,
            0,
            &texture
        ) == kCVReturnSuccess
    }
}
