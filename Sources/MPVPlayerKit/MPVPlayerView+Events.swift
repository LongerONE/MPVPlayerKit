import AVFoundation
import QuartzCore
import UIKit
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

final class MPVPlayerViewWeakTransfer: @unchecked Sendable {
    weak var value: MPVPlayerView?

    init(_ value: MPVPlayerView) {
        self.value = value
    }
}

func makeMPVTimeTimerHandler(_ playerView: MPVPlayerView) -> @Sendable () -> Void {
    let transfer = MPVPlayerViewWeakTransfer(playerView)
    return {
        transfer.value?.publishTime()
    }
}

extension MPVPlayerView {
    nonisolated func publishTime() {
        guard mpv != nil else { return }
        let current = getDouble(MPVProperty.timePosition)
        let total = getDouble(MPVProperty.duration)
        guard current.isFinite else { return }

        let nextCurrentTime = max(0.0, current)
        let nextDuration = total.isFinite && total > 0.0 ? total : nil
        notifyOnMain {
            guard self.mpv != nil else { return }
            self.currentTime = nextCurrentTime
            if let nextDuration {
                self.duration = nextDuration
            }

            if self.hasReportedReadyToPlay == false, self.duration > 0.0 {
                self.hasReportedReadyToPlay = true
                self.notifyState(.readyToPlay)
            }
            self.updateClientSubtitle(at: self.currentTime)
            self.notifyTime(currentTime: self.currentTime, duration: self.duration)
        }
    }

    nonisolated func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.mpv {
                guard let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE else {
                    break
                }

                switch event.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    self.handlePropertyChange(event)
                case MPV_EVENT_FILE_LOADED:
                    self.mpvDebugLog(
                        "event file-loaded profile=\(self.activeProfileDescription)"
                    )
                    self.refreshMediaTracksCache()
                    self.refreshPictureInPictureVideoDisplaySize()
                case MPV_EVENT_PLAYBACK_RESTART:
                    self.mpvDebugLog(
                        "event playback-restart stage=begin "
                            + "profile=\(self.activeProfileDescription)"
                    )
                    self.hasPlaybackRestarted = true
                    self.mpvDebugLog("event playback-restart stage=decoder-diagnostics-begin")
                    self.refreshDecoderModeAfterPlaybackRestart()
                    self.mpvDebugLog("event playback-restart stage=decoder-diagnostics-end")
                    if self.hasLoggedVideoColorParameters == false {
                        self.hasLoggedVideoColorParameters = true
                        self.mpvDebugLog("event playback-restart stage=color-diagnostics-begin")
                        self.logVideoColorParameters()
                        self.mpvDebugLog("event playback-restart stage=color-diagnostics-end")
                    }
                    self.refreshPictureInPictureVideoDisplaySize()
                    self.mpvDebugLog("event playback-restart stage=end")
                case MPV_EVENT_VIDEO_RECONFIG:
                    self.refreshPictureInPictureVideoDisplaySize()
                case MPV_EVENT_END_FILE:
                    self.mpvDebugLog("event end-file stage=begin")
                    self.handleEndFile(event)
                case MPV_EVENT_SHUTDOWN:
                    self.mpvDebugLog("event shutdown")
                    self.notifyOnMain {
                        self.stopTimeTimer()
                        self.isPlaying = false
                    }
                case MPV_EVENT_LOG_MESSAGE:
                    self.logMessage(event)
                case MPV_EVENT_COMMAND_REPLY:
                    self.handleCommandReply(event)
                default:
                    break
                }
            }
        }
    }

    nonisolated func handleCommandReply(_ event: UnsafeMutablePointer<mpv_event>) {
        dispatchPrecondition(condition: .onQueue(queue))
        let userdata = event.pointee.reply_userdata
        if let canceled = canceledExternalSubtitleCommands.removeValue(forKey: userdata) {
            restoreAfterStaleExternalReplyIfNeeded(canceled)
            return
        }
        guard let pending = pendingExternalSubtitleLoad,
              pending.userdata == userdata,
              pending.selectionEpoch == subtitleSelectionEpoch else { return }
        pendingExternalSubtitleLoad = nil
        let subtitleID = event.pointee.error >= 0
            ? externalSubtitleTrackID(
                source: pending.source,
                urlString: pending.url,
                preferringIDsNotIn: pending.trackIDsBeforeLoad
            )
            : nil
        let success = subtitleID.map { subtitleID in
            performSubtitleSelectionTransaction(
                previous: pending.previousSelection,
                targetUsesOriginalStyle: pending.usesOriginalStyle,
                targetSubtitleID: subtitleID,
                targetVisibility: true
            )
        } ?? false
        if success, let subtitleID {
            loadedExternalSubtitleIDs[pending.url] = subtitleID
            activeExternalSubtitleActivation = ExternalSubtitleActivation(
                selectionEpoch: pending.selectionEpoch,
                subtitleID: subtitleID,
                previousSelection: pending.previousSelection,
                requestIDs: Set(pending.requestIDs)
            )
        }
        mpvDebugLog("loadSubtitle reply requests=\(pending.requestIDs) userdata=\(userdata) sid=\(subtitleID.map(String.init) ?? "nil") success=\(success) error=\(event.pointee.error)")
        pending.requestIDs.forEach { notifySubtitleLoad(requestID: $0, success: success) }
    }

    nonisolated func cancelPendingExternalSubtitleLoad(handle: OpaquePointer, reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let pending = pendingExternalSubtitleLoad else { return }
        pendingExternalSubtitleLoad = nil
        canceledExternalSubtitleCommands[pending.userdata] = pending
        mpv_abort_async_command(handle, pending.userdata)
        if restoreSubtitleSelection(pending.previousSelection) == false {
            mpvDebugLog("loadSubtitle cancel restore failed userdata=\(pending.userdata) reason=\(reason)")
        }
        mpvDebugLog("loadSubtitle cancelled userdata=\(pending.userdata) reason=\(reason)")
        pending.requestIDs.forEach { notifySubtitleLoad(requestID: $0, success: false) }
    }

    @discardableResult
    nonisolated func beginNewSubtitleSelection(reason: String) -> UInt64 {
        dispatchPrecondition(condition: .onQueue(queue))
        subtitleSelectionEpoch &+= 1
        if let mpv {
            cancelPendingExternalSubtitleLoad(handle: mpv, reason: reason)
        } else if let pending = pendingExternalSubtitleLoad {
            pendingExternalSubtitleLoad = nil
            pending.requestIDs.forEach { notifySubtitleLoad(requestID: $0, success: false) }
        }
        activeExternalSubtitleActivation = nil
        return subtitleSelectionEpoch
    }

    nonisolated func captureSubtitleSelection() -> SubtitleSelectionSnapshot {
        SubtitleSelectionSnapshot(
            usesOriginalStyle: currentSubtitleUsesOriginalStyle,
            subtitleID: getInt64(MPVProperty.subtitleID),
            isVisible: getFlag(MPVProperty.subtitleVisibility) ?? false
        )
    }

    nonisolated func logicalSubtitleSelection() -> SubtitleSelectionSnapshot {
        if let committedSubtitleSelection { return committedSubtitleSelection }
        let initial = captureSubtitleSelection()
        committedSubtitleSelection = initial
        return initial
    }

    nonisolated func performSubtitleSelectionTransaction(
        previous: SubtitleSelectionSnapshot,
        targetUsesOriginalStyle: Bool,
        targetSubtitleID: Int64?,
        targetVisibility: Bool
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        _ = command("set", args: [MPVProperty.subtitleVisibility, "no"], checkForErrors: false)
        let styleSucceeded = applySubtitleStyleMode(usesOriginalStyle: targetUsesOriginalStyle)
        let sidSucceeded = command(
            "set",
            args: [MPVProperty.subtitleID, targetSubtitleID.map(String.init) ?? "no"],
            checkForErrors: false
        ) >= 0
        let visibilitySucceeded = command(
            "set",
            args: [MPVProperty.subtitleVisibility, targetVisibility ? "yes" : "no"],
            checkForErrors: false
        ) >= 0
        guard styleSucceeded, sidSucceeded, visibilitySucceeded else {
            if restoreSubtitleSelection(previous) == false {
                enterSafeSubtitleState(reason: "transaction-rollback-failed")
            }
            return false
        }
        currentSubtitleUsesOriginalStyle = targetUsesOriginalStyle
        committedSubtitleSelection = SubtitleSelectionSnapshot(
            usesOriginalStyle: targetUsesOriginalStyle,
            subtitleID: targetSubtitleID,
            isVisible: targetVisibility
        )
        return true
    }

    @discardableResult
    nonisolated func restoreSubtitleSelection(_ snapshot: SubtitleSelectionSnapshot) -> Bool {
        let hideSucceeded = command("set", args: [MPVProperty.subtitleVisibility, "no"], checkForErrors: false) >= 0
        let styleSucceeded = applySubtitleStyleMode(usesOriginalStyle: snapshot.usesOriginalStyle)
        let sidSucceeded = command(
            "set",
            args: [MPVProperty.subtitleID, snapshot.subtitleID.map(String.init) ?? "no"],
            checkForErrors: false
        ) >= 0
        let visibilitySucceeded = command(
            "set",
            args: [MPVProperty.subtitleVisibility, snapshot.isVisible ? "yes" : "no"],
            checkForErrors: false
        ) >= 0
        guard hideSucceeded, styleSucceeded, sidSucceeded, visibilitySucceeded else { return false }
        currentSubtitleUsesOriginalStyle = snapshot.usesOriginalStyle
        committedSubtitleSelection = snapshot
        return true
    }

    nonisolated func enterSafeSubtitleState(reason: String) {
        let hidden = command("set", args: [MPVProperty.subtitleVisibility, "no"], checkForErrors: false) >= 0
        let disabled = command("set", args: [MPVProperty.subtitleID, "no"], checkForErrors: false) >= 0
        if hidden, disabled {
            if let override = getString(MPVProperty.subtitleASSOverride) {
                currentSubtitleUsesOriginalStyle = override == "no"
            }
            committedSubtitleSelection = SubtitleSelectionSnapshot(
                usesOriginalStyle: currentSubtitleUsesOriginalStyle,
                subtitleID: nil,
                isVisible: false
            )
        } else {
            committedSubtitleSelection = nil
        }
        mpvDebugLog("subtitle entered safe state reason=\(reason) hidden=\(hidden) disabled=\(disabled)")
        // Subtitle recovery failures are non-fatal to video playback. Keep the
        // video running with subtitles disabled instead of publishing the
        // global player error state, which presents the playback failure UI.
    }

    nonisolated func cancelExternalSubtitleRequestOnMPVQueue(requestID: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        if var pending = pendingExternalSubtitleLoad, pending.requestIDs.contains(requestID) {
            pending.requestIDs.removeAll(where: { $0 == requestID })
            if pending.requestIDs.isEmpty {
                pendingExternalSubtitleLoad = nil
                canceledExternalSubtitleCommands[pending.userdata] = pending
                subtitleSelectionEpoch &+= 1
                if let mpv { mpv_abort_async_command(mpv, pending.userdata) }
                if restoreSubtitleSelection(pending.previousSelection) == false {
                    enterSafeSubtitleState(reason: "cancel-pending-restore-failed")
                }
            } else {
                pendingExternalSubtitleLoad = pending
            }
            notifySubtitleLoad(requestID: requestID, success: false)
            return
        }
        if var activation = activeExternalSubtitleActivation,
           activation.requestIDs.remove(requestID) != nil {
            if activation.requestIDs.isEmpty {
                if activation.selectionEpoch == subtitleSelectionEpoch,
                   getInt64(MPVProperty.subtitleID) == activation.subtitleID {
                    subtitleSelectionEpoch &+= 1
                    if restoreSubtitleSelection(activation.previousSelection) == false {
                        enterSafeSubtitleState(reason: "cancel-activation-restore-failed")
                    }
                }
                activeExternalSubtitleActivation = nil
            } else {
                activeExternalSubtitleActivation = activation
            }
        }
        notifySubtitleLoad(requestID: requestID, success: false)
    }

    nonisolated func restoreAfterStaleExternalReplyIfNeeded(_ canceled: PendingExternalSubtitleLoad) {
        guard let staleSubtitleID = externalSubtitleTrackID(
            source: canceled.source,
            urlString: canceled.url,
            preferringIDsNotIn: canceled.trackIDsBeforeLoad
        ), canceled.trackIDsBeforeLoad.contains(staleSubtitleID) == false,
           getInt64(MPVProperty.subtitleID) == staleSubtitleID else { return }
        // A canceled `sub-add auto` selected itself in a special auto-selection case.
        // Restore the selection that is current at reply time, unless no newer selection committed.
        guard let committedSubtitleSelection else {
            enterSafeSubtitleState(reason: "stale-reply-missing-committed-selection")
            return
        }
        if restoreSubtitleSelection(committedSubtitleSelection) == false {
            enterSafeSubtitleState(reason: "stale-reply-restore-failed")
        }
    }

    nonisolated func notifySubtitleLoad(requestID: String, success: Bool) {
        notifyOnMain {
            NotificationCenter.default.post(
                name: MPVPlayerKitNotification.didLoadSubtitle,
                object: self,
                userInfo: [
                    MPVPlayerKitNotificationKey.requestID: requestID,
                    MPVPlayerKitNotificationKey.success: success,
                ]
            )
        }
    }

    nonisolated func handleEndFile(_ event: UnsafeMutablePointer<mpv_event>) {
        let endFile = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
        let errorCode = endFile?.error ?? 0
        let reason = endFile?.reason
        notifyOnMain {
            self.handleEndFileOnMain(reason: reason, errorCode: errorCode)
        }
    }

    func handleEndFileOnMain(reason: mpv_end_file_reason?, errorCode: CInt) {
        let errorMessage = errorCode == 0 ? "none" : String(cString: mpv_error_string(errorCode))
        guard let reason else {
            mpvDebugLog("event end-file missing reason error=\(errorCode) message=\(errorMessage) profile=\(activeProfileDescription)")
            if retryNextProfileAfterPlaybackFailure(errorCode: errorCode) {
                return
            }
            notifyOnMain {
                self.stopTimeTimer()
                self.isPlaying = false
                self.notifyState(.error)
            }
            return
        }
        mpvDebugLog("event end-file reason=\(String(describing: reason)) error=\(errorCode) message=\(errorMessage) profile=\(activeProfileDescription) hasReady=\(hasReportedReadyToPlay) hasRestarted=\(hasPlaybackRestarted)")

        if reason == MPV_END_FILE_REASON_ERROR {
            if retryNextProfileAfterPlaybackFailure(errorCode: errorCode) {
                return
            }
            notifyOnMain {
                self.stopTimeTimer()
                self.isPlaying = false
                self.notifyState(.error)
            }
            return
        }

        if reason == MPV_END_FILE_REASON_EOF {
            notifyOnMain {
                self.stopTimeTimer()
                self.isPlaying = false
                self.notifyState(.playedToTheEnd)
            }
            return
        }

        if reason == MPV_END_FILE_REASON_STOP || reason == MPV_END_FILE_REASON_QUIT || reason == MPV_END_FILE_REASON_REDIRECT {
            notifyOnMain {
                self.stopTimeTimer()
                self.isPlaying = false
            }
            return
        }

        if retryNextProfileAfterPlaybackFailure(errorCode: errorCode) {
            return
        }
        notifyOnMain {
            self.stopTimeTimer()
            self.isPlaying = false
            self.notifyState(.error)
        }
    }

    func retryNextProfileAfterPlaybackFailure(errorCode: CInt) -> Bool {
        guard hasReportedReadyToPlay == false, hasPlaybackRestarted == false else {
            mpvDebugLog("profile retry skipped playback already started profile=\(activeProfileDescription) error=\(errorCode)")
            return false
        }
        guard let url else {
            mpvDebugLog("profile retry skipped missing url error=\(errorCode)")
            return false
        }
        let nextIndex = activeSetupProfileIndex + 1
        guard nextIndex < setupProfiles.count else {
            mpvDebugLog("profile retry skipped no more profiles current=\(activeProfileDescription) error=\(errorCode)")
            return false
        }

        let oldProfile = activeProfileDescription
        destroyMPVHandle(reason: "profile-\(oldProfile)-end-file-error-\(errorCode)", sendStopCommand: false)
        activeSetupProfileIndex = nextIndex
        hasReportedReadyToPlay = false
        hasPlaybackRestarted = false
        mpvDebugLog("profile retry next old=\(oldProfile) next=\(activeProfileDescription) error=\(errorCode)")
        return setupMPV(url: url, profile: setupProfiles[activeSetupProfileIndex])
    }

    nonisolated func handlePropertyChange(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let data = event.pointee.data else {
            return
        }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        let propertyName = String(cString: property.name)
        switch propertyName {
        case MPVProperty.pausedForCache:
            let bufferingValue = property.data?.assumingMemoryBound(to: Int32.self).pointee ?? 0
            let buffering = bufferingValue != 0
            notifyOnMain {
                if buffering {
                    self.stopTimeTimer()
                } else if self.isPlaying {
                    self.startTimeTimer()
                }
                self.notifyBufferingProgress(buffering ? 0 : 100)
                self.notifyState(buffering ? .buffering : .bufferFinished)
            }
        case MPVProperty.subtitleText:
            logSubtitleTextChange()
        default:
            break
        }
    }

    nonisolated func refreshPictureInPictureVideoDisplaySize() {
        let width = getInt64(MPVProperty.videoOutputDisplayWidth) ?? 0
        let height = getInt64(MPVProperty.videoOutputDisplayHeight) ?? 0
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        notifyOnMain {
            self.updatePictureInPictureVideoDisplaySize(size)
        }
    }

}
