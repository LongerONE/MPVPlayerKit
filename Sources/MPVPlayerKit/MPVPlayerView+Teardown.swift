import Foundation
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

final class MPVWakeupContext: @unchecked Sendable {
    weak var playerView: MPVPlayerView?

    init(_ playerView: MPVPlayerView) {
        self.playerView = playerView
    }
}

/// 不持有 `MPVPlayerView` 的销毁令牌，供 deinit 在无强引用时安全 terminate。
final class MPVHandleTeardown: @unchecked Sendable {
    private let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    func terminate() {
        mpv_terminate_destroy(handle)
    }
}

func mpvPlayerWakeupCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let wakeup = Unmanaged<MPVWakeupContext>.fromOpaque(context).takeUnretainedValue()
    wakeup.playerView?.readEvents()
}

extension MPVPlayerView {
    /// deinit 专用：只摘句柄与回调，不复活 self。
    nonisolated func detachHandleForDeinitTeardown() -> OpaquePointer? {
        mpvHandleLock.lock()
        let handle = mpv
        mpv = nil
        let timer = timeTimer
        timeTimer = nil
        let wakeup = wakeupContextTransfer
        wakeupContextTransfer = nil
        mpvHandleLock.unlock()
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
        }
        wakeup?.release()
        if let handle {
            let teardown = MPVHandleTeardown(handle: handle)
            queue.async {
                timer?.setEventHandler {}
                timer?.cancel()
                teardown.terminate()
            }
        } else {
            timer?.setEventHandler {}
            timer?.cancel()
        }
        return handle
    }

    func destroyMPVHandle(reason: String, sendStopCommand: Bool = true) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.stopPictureInPictureForPlayerTeardown()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.stopPictureInPictureForPlayerTeardown()
                }
            }
        }

        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            destroyMPVHandleOnMPVQueue(reason: reason, sendStopCommand: sendStopCommand)
        } else {
            // mpv_terminate_destroy may wait for decoder/rendering work. The
            // caller must not synchronously wait for the MPV queue here.
            // weak：禁止 deinit/释放路径经 [self] 复活对象。
            queue.async { [weak self] in
                self?.destroyMPVHandleOnMPVQueue(reason: reason, sendStopCommand: sendStopCommand)
            }
        }
    }

    private func destroyMPVHandleOnMPVQueue(reason: String, sendStopCommand: Bool) {
        recordDiagnosticEvent("销毁解码配置", fields: ["原因": reason, "配置": activeProfileDescription])
        if reason == "stop" || reason == "setup-failed" { finishPowerDiagnostics(reason: reason) }
        diagnosticProbe?.clearStaticMPVFieldCache()
        MPVSystemPlaybackCoordinator.shared.deactivate(playerView: self)
        setDecoderMode(.initializing)
        _ = nextBufferingSessionGeneration()
        clearMPVPlaybackUpdateSourceSession()
        clearPendingPlaybackPositionUpdate()
        resetBufferingStateOnMPVQueue(reason: "destroy-\(reason)", notifyFinish: true)
        stopTimeTimer()
        clearMediaTracksCache()
        clearSubtitleTextCache()
        notifyOnMain {
            self.updatePictureInPictureVideoDisplaySize(.zero)
        }
        performOnMPVQueueSync {
            let pendingRequestIDs = pendingExternalSubtitleLoad?.requestIDs ?? []
            if let mpv, let pending = pendingExternalSubtitleLoad {
                mpv_abort_async_command(mpv, pending.userdata)
            }
            pendingExternalSubtitleLoad = nil
            let pendingSeekRequests = Array(pendingSeekCommands.values)
            pendingSeekCommands.removeAll(keepingCapacity: true)
            pendingSeekRequests.forEach {
                notifySeekCompletion(
                    request: $0.request,
                    success: false,
                    error: MPV_ERROR_UNINITIALIZED.rawValue
                )
            }
            loadedExternalSubtitleIDs.removeAll(keepingCapacity: true)
            canceledExternalSubtitleCommands.removeAll(keepingCapacity: true)
            activeExternalSubtitleActivation = nil
            committedSubtitleSelection = nil
            nextMPVCommandUserdata = 1
            subtitleSelectionEpoch = 0
            currentSubtitleUsesOriginalStyle = false
            pendingRequestIDs.forEach { notifySubtitleLoad(requestID: $0, success: false) }
            mpvHandleLock.lock()
            let handleToDestroy = mpv
            mpv = nil
            let pendingWakeup = wakeupContextTransfer
            wakeupContextTransfer = nil
            mpvHandleLock.unlock()
            guard let mpv = handleToDestroy else {
                pendingWakeup?.release()
                lastMPVTimeSnapshot = nil
                markColorOutputRendererStopped()
                mpvDebugLog("destroyMPVHandle skipped reason=\(reason) handle=nil")
                return
            }
            mpvDebugLog("destroyMPVHandle begin reason=\(reason) handle=\(mpv)")
            mpv_set_wakeup_callback(mpv, nil, nil)
            pendingWakeup?.release()
            mpvDebugLog("destroyMPVHandle stage=wakeup-cleared reason=\(reason)")
            mpvDebugLog("destroyMPVHandle stage=handle-detached reason=\(reason)")
            if sendStopCommand {
                let stopStatus = command("stop", handle: mpv, checkForErrors: false)
                mpvDebugLog("destroyMPVHandle stop command status=\(stopStatus)")
            }
            mpvDebugLog("destroyMPVHandle stage=terminate-begin reason=\(reason)")
            mpv_terminate_destroy(mpv)
            markColorOutputRendererStopped()
            mpvDebugLog("destroyMPVHandle stage=terminate-end reason=\(reason)")
            lastMPVTimeSnapshot = nil
        }
    }
}
