import Foundation
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

extension MPVPlayerView {
    func retryNextProfileAfterPlaybackFailure(errorCode: CInt) -> Bool {
        let profile = activeSetupProfileSnapshot()
        let activeProfile = setupProfile(at: profile.index)
        let playbackHadStarted = isReadyToPlayReported() || isPlaybackRestarted()
        let usesHardwareDecode = activeProfile?.options.first {
            $0.0 == "hwdec"
        }?.1.caseInsensitiveCompare("no") != .orderedSame

        guard playbackHadStarted == false || usesHardwareDecode else {
            mpvDebugLog(
                "profile retry skipped software playback already started "
                    + "profile=\(activeProfileDescription) error=\(errorCode)"
            )
            return false
        }
        guard let url else {
            mpvDebugLog("profile retry skipped missing url error=\(errorCode)")
            return false
        }

        let nextIndex = profile.index + 1
        guard nextIndex < profile.count else {
            mpvDebugLog("profile retry skipped no more profiles current=\(activeProfileDescription) error=\(errorCode)")
            return false
        }

        let session = currentBufferingSessionGeneration()
        let intent = currentPlaybackIntentGeneration()
        let resumeTime = playbackHadStarted ? max(currentTime, 0) : 0
        let shouldPlay = isPlaying
        queue.async { [weak self] in
            guard let self, !self.isStopped(),
                  self.currentBufferingSessionGeneration() == session else { return }
            if playbackHadStarted {
                self.pendingProfileRetry = (resumeTime, shouldPlay && self.isPlaybackIntentCurrent(intent))
            }
            let success = self.retryProfileOnMPVQueue(url: url, nextIndex: nextIndex,
                count: profile.count, errorCode: errorCode)
            if !success {
                let failureSession = self.queueConfigurationGeneration
                self.notifyOnMain {
                    guard !self.isStopped(), self.currentBufferingSessionGeneration() == failureSession,
                          self.isPlaybackIntentCurrent(intent) else { return }
                    self.stopSystemPlaybackProgress(keepingOwner: true)
                    self.notifyState(.error)
                }
            }
        }
        return true
    }

    private nonisolated func retryProfileOnMPVQueue(
        url: URL, nextIndex: Int, count: Int, errorCode: CInt
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let oldProfile = activeProfileDescription
        destroyMPVHandle(reason: "profile-\(oldProfile)-end-file-error-\(errorCode)", sendStopCommand: false)
        var index = nextIndex
        while index < count, !isStopped(), currentBufferingSessionGeneration() == queueConfigurationGeneration {
            setActiveSetupProfileIndex(index)
            prepareProfilesForNextRenderer()
            setReadyToPlayReported(false)
            setPlaybackRestarted(false)
            guard let nextProfile = setupProfile(at: index) else { return false }
            if setupMPV(url: url, profile: nextProfile) {
                recordDiagnosticEvent("解码配置回退", fields: ["原配置": oldProfile, "新配置": nextProfile.name])
                return true
            }
            index += 1
        }
        return false
    }

    nonisolated func restoreProfileRetryIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let pendingProfileRetry else { return }
        self.pendingProfileRetry = nil

        updateBufferingPlaybackIntent(pendingProfileRetry.shouldPlay ? .playing : .userPaused)
        setFlag(MPVProperty.pause, pendingProfileRetry.shouldPlay == false)
        if pendingProfileRetry.resumeTime > 0.0 {
            let status = command(
                "seek",
                args: [String(pendingProfileRetry.resumeTime), "absolute+exact"],
                checkForErrors: false
            )
            mpvDebugLog(
                "profile retry resume time=\(pendingProfileRetry.resumeTime) status=\(status)"
            )
        }
        if pendingProfileRetry.shouldPlay {
            startTimeTimer()
        }
    }
}
