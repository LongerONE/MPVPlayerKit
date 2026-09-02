import UIKit
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

extension MPVPlayerView {
    /// MoltenVK reads CAMetalLayer.drawableSize during reconfig, but the
    /// public libmpv bridge does not expose VOCTRL_EXTERNAL_RESIZE. Toggle
    /// gpu-context to enter mpv's UPDATE_VO path after final rotation geometry
    /// is applied, without reloading the URL or changing playback position.
    @discardableResult
    func requestRendererGeometryRefresh(for geometry: MPVMetalLayerGeometry) -> Bool {
        guard mpv != nil, isStopped() == false else {
            mpvDebugLog(
                "renderer geometry refresh skipped "
                    + "target=\(geometry.drawableSize) stopped=\(isStopped())"
            )
            return false
        }

        rendererGeometryRefreshID &+= 1
        let refreshID = rendererGeometryRefreshID
        activeRendererGeometryRefreshID = refreshID
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv, self.isStopped() == false else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishRendererGeometryRefresh(id: refreshID, reason: "handle-unavailable")
                }
                return
            }

            let context = self.rendererGeometryRefreshUsesAutoContext ? "moltenvk" : "auto"
            self.rendererGeometryRefreshUsesAutoContext.toggle()
            self.pendingRendererGeometryRefreshID = refreshID
            self.mpvDebugLog(
                "renderer geometry refresh requested "
                    + "id=\(refreshID) gpu-context=\(context) "
                    + "targetDrawable=\(geometry.drawableSize)"
            )
            let status = mpv_set_option_string(mpv, "gpu-context", context)
            self.mpvDebugLog(
                "renderer geometry refresh submitted "
                    + "id=\(refreshID) gpu-context=\(context) status=\(status)"
            )
            guard status >= 0 else {
                self.pendingRendererGeometryRefreshID = nil
                DispatchQueue.main.async { [weak self] in
                    self?.finishRendererGeometryRefresh(id: refreshID, reason: "option-failed")
                }
                return
            }

            // Keep suppression bounded if this libmpv build emits no
            // video-reconfig event.
            self.queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self,
                      self.pendingRendererGeometryRefreshID == refreshID else {
                    return
                }
                self.pendingRendererGeometryRefreshID = nil
                self.mpvDebugLog("renderer geometry refresh timeout id=\(refreshID)")
                DispatchQueue.main.async { [weak self] in
                    self?.finishRendererGeometryRefresh(id: refreshID, reason: "timeout")
                }
            }
        }
        return true
    }

    func finishRendererGeometryRefresh(id: Int, reason: String) {
        guard activeRendererGeometryRefreshID == id else { return }
        activeRendererGeometryRefreshID = nil
        mpvDebugLog(
            "renderer geometry refresh finished id=\(id) reason=\(reason) "
                + "bounds=\(bounds) drawable=\(metalLayer.drawableSize) "
                + "current=\(currentTime) duration=\(duration) playing=\(isPlaying)"
        )
        animateGeometryTransitionIn()
    }
}
