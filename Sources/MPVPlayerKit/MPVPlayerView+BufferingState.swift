import Foundation
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#else
#error("MPVPlayerKit requires MPVKit's Libmpv module.")
#endif

extension MPVPlayerView {
    nonisolated static let bufferingFallbackDelay: DispatchTimeInterval = .milliseconds(300)

    nonisolated func handleBufferingPropertyChange(_ property: mpv_event_property) {
        dispatchPrecondition(condition: .onQueue(queue))
        var snapshot = bufferingStateMachine.snapshot
        let propertyName = String(cString: property.name)
        switch propertyName {
        case MPVProperty.pausedForCache:
            snapshot.pausedForCache = bufferingFlagValue(property)
        case MPVProperty.cacheBufferingState:
            snapshot.cacheBufferingState = bufferingDoubleValue(property)
        case MPVProperty.coreIdle:
            snapshot.coreIdle = bufferingFlagValue(property)
        case MPVProperty.pause:
            snapshot.pause = bufferingFlagValue(property)
        case MPVProperty.idleActive:
            snapshot.idleActive = bufferingFlagValue(property)
        case MPVProperty.eofReached:
            snapshot.eofReached = bufferingFlagValue(property)
        case MPVProperty.seeking:
            snapshot.seeking = bufferingFlagValue(property) ?? true
        default:
            return
        }
        reduceBufferingState(.snapshot(snapshot))
    }

    nonisolated func updateBufferingPropertyOnQueue(name: String, value: Bool?) {
        dispatchPrecondition(condition: .onQueue(queue))
        var snapshot = bufferingStateMachine.snapshot
        switch name {
        case MPVProperty.pausedForCache:
            snapshot.pausedForCache = value
        case MPVProperty.coreIdle:
            snapshot.coreIdle = value
        case MPVProperty.pause:
            snapshot.pause = value
        case MPVProperty.idleActive:
            snapshot.idleActive = value
        case MPVProperty.eofReached:
            snapshot.eofReached = value
        case MPVProperty.seeking:
            snapshot.seeking = value ?? true
        default:
            return
        }
        reduceBufferingState(.snapshot(snapshot))
    }

    nonisolated func updateBufferingPlaybackIntent(
        _ intent: MPVBufferingSnapshot.PlaybackIntent
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        var snapshot = bufferingStateMachine.snapshot
        snapshot.playbackIntent = intent
        if intent != .playing {
            snapshot.seeking = false
        }
        reduceBufferingState(.snapshot(snapshot))
    }

    nonisolated func markBufferingFileLoaded() {
        dispatchPrecondition(condition: .onQueue(queue))
        var snapshot = bufferingStateMachine.snapshot
        snapshot.fileLoaded = true
        snapshot.seeking = false
        snapshot.ended = false
        snapshot.failed = false
        snapshot.eofReached = false
        reduceBufferingState(.snapshot(snapshot))
    }

    nonisolated func markBufferingSeekStarted() {
        dispatchPrecondition(condition: .onQueue(queue))
        bufferingActiveSeekCount += 1
        var snapshot = bufferingStateMachine.snapshot
        snapshot.seeking = true
        reduceBufferingState(.snapshot(snapshot))
    }

    nonisolated func markBufferingSeekFinished() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard bufferingActiveSeekCount > 0 else { return }
        bufferingActiveSeekCount -= 1
        guard bufferingActiveSeekCount == 0 else { return }
        var snapshot = bufferingStateMachine.snapshot
        snapshot.seeking = false
        reduceBufferingState(.snapshot(snapshot))
    }

    nonisolated func resetBufferingStateOnMPVQueue(
        reason: String,
        notifyFinish: Bool = false
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        mpvDebugLog("buffering reset reason=\(reason)")
        bufferingActiveSeekCount = 0
        let decision = bufferingStateMachine.reduce(.reset)
        applyBufferingFallbackAction(decision.fallbackAction)
        applyBufferingDecision(decision, forceFinishNotification: notifyFinish)
    }

    nonisolated func handleBufferingPlaybackRestart() {
        dispatchPrecondition(condition: .onQueue(queue))
        let decision = bufferingStateMachine.reduce(.playbackRestart)
        applyBufferingFallbackAction(decision.fallbackAction)
        applyBufferingDecision(decision)
    }

    nonisolated func reduceBufferingState(_ input: MPVBufferingInput) {
        dispatchPrecondition(condition: .onQueue(queue))
        let decision = bufferingStateMachine.reduce(input)
        applyBufferingFallbackAction(decision.fallbackAction)
        applyBufferingDecision(decision)
    }

    nonisolated private func applyBufferingFallbackAction(
        _ action: MPVBufferingFallbackAction
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        switch action {
        case .none:
            break
        case .schedule:
            scheduleBufferingFallback()
        case .cancel:
            cancelBufferingFallback()
        }
    }

    nonisolated private func scheduleBufferingFallback() {
        dispatchPrecondition(condition: .onQueue(queue))
        bufferingFallbackGeneration &+= 1
        let generation = bufferingFallbackGeneration
        bufferingFallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.bufferingFallbackGeneration == generation,
                  self.bufferingFallbackWorkItem?.isCancelled == false
            else {
                return
            }
            self.bufferingFallbackWorkItem = nil
            self.reduceBufferingState(.fallbackElapsed)
        }
        bufferingFallbackWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.bufferingFallbackDelay, execute: workItem)
    }

    nonisolated private func cancelBufferingFallback() {
        dispatchPrecondition(condition: .onQueue(queue))
        bufferingFallbackGeneration &+= 1
        bufferingFallbackWorkItem?.cancel()
        bufferingFallbackWorkItem = nil
    }

    nonisolated private func applyBufferingDecision(
        _ decision: MPVBufferingDecision,
        forceFinishNotification: Bool = false
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        let isBuffering = decision.state == .buffering
        if isBuffering {
            stopTimeTimer()
        } else if isPlaying {
            startTimeTimer()
        }

        let shouldNotifyState = decision.stateChanged
            || (forceFinishNotification && isBuffering == false)
        let shouldNotifyProgress = decision.progressChanged || shouldNotifyState
        guard shouldNotifyState || shouldNotifyProgress else { return }
        let sessionGeneration = currentBufferingSessionGeneration()
        let intentGeneration = currentPlaybackIntentGeneration()
        mpvDebugLog(
            "buffering decision state=\(isBuffering ? "buffering" : "finished") "
                + "stateChanged=\(decision.stateChanged) progress=\(decision.progress) "
                + "progressChanged=\(decision.progressChanged) "
                + "reason=\(String(describing: decision.reason))"
        )

        notifyOnMain {
            guard self.currentBufferingSessionGeneration() == sessionGeneration,
                  self.currentPlaybackIntentGeneration() == intentGeneration,
                  self.isStopped() == false || isBuffering == false
            else { return }
            if shouldNotifyProgress {
                self.notifyBufferingProgress(decision.progress)
            }
            if shouldNotifyState {
                self.notifyState(isBuffering ? .buffering : .bufferFinished)
            }
        }
    }

    nonisolated private func bufferingFlagValue(_ property: mpv_event_property) -> Bool? {
        guard property.format == MPV_FORMAT_FLAG,
              let data = property.data else { return nil }
        return data.assumingMemoryBound(to: Int32.self).pointee != 0
    }

    nonisolated private func bufferingDoubleValue(_ property: mpv_event_property) -> Double? {
        guard property.format == MPV_FORMAT_DOUBLE,
              let data = property.data else { return nil }
        return data.assumingMemoryBound(to: Double.self).pointee
    }
}
