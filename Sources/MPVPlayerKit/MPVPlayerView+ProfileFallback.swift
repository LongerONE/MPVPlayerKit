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

        var nextIndex = profile.index + 1
        guard nextIndex < profile.count else {
            mpvDebugLog("profile retry skipped no more profiles current=\(activeProfileDescription) error=\(errorCode)")
            return false
        }

        if playbackHadStarted {
            let resumeTime = max(currentTime, 0.0)
            let shouldPlay = isPlaying
            pendingProfileRetry = (resumeTime: resumeTime, shouldPlay: shouldPlay)
        }

        let oldProfile = activeProfileDescription
        destroyMPVHandle(reason: "profile-\(oldProfile)-end-file-error-\(errorCode)", sendStopCommand: false)

        while nextIndex < profile.count {
            setActiveSetupProfileIndex(nextIndex)
            prepareProfilesForNextRenderer()
            setReadyToPlayReported(false)
            setPlaybackRestarted(false)
            resetPictureInPictureVideoDisplaySize()
            guard let nextProfile = setupProfile(at: nextIndex) else {
                mpvDebugLog("profile retry skipped missing rebuilt profile next=\(nextIndex) error=\(errorCode)")
                return false
            }
            mpvDebugLog("profile retry next old=\(oldProfile) next=\(nextProfile.name) error=\(errorCode)")
            if setupMPV(url: url, profile: nextProfile) {
                recordDiagnosticEvent(
                    "解码配置回退",
                    fields: ["原配置": oldProfile, "新配置": nextProfile.name]
                )
                return true
            }
            nextIndex += 1
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
