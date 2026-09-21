import CoreGraphics
import Foundation
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

/// 渲染输出配置：模拟器用软件渲染，真机用 Metal `wid`。
/// 必须对真机与模拟器同时编译（不可包在 `#if targetEnvironment(simulator)` 内）。
extension MPVPlayerView {
    nonisolated func configureMPVRenderOutput(
        mpv: OpaquePointer,
        profileName: String
    ) -> Bool {
#if targetEnvironment(simulator)
        guard let renderer = MPVSoftwareRenderer(mpv: mpv, playerView: self) else {
            mpvDebugLog("software render context failed profile=\(profileName)")
            return false
        }
        softwareRenderer = renderer
        recordDiagnosticEvent("软件渲染初始化", fields: ["配置": profileName])
        return true
#else
        var metalLayerHandle = Int64(
            Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque())
        )
        return checkError(
            mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &metalLayerHandle),
            operation: "set_option wid",
            notifyOnFailure: false
        )
#endif
    }
}

#if targetEnvironment(simulator)
extension MPVPlayerView {
    nonisolated func publishSoftwareFrame(_ image: CGImage) {
        notifyOnMain {
            self.softwareVideoLayer.contents = image
            self.softwareVideoLayer.frame = self.bounds
        }
    }
}
#endif
