import UIKit

extension MPVQuickPlayerViewController {
    func updateIdleTimer(for state: MPVPlaybackState) {
        guard Self.shouldKeepScreenAwake(for: state) else {
            restoreIdleTimer()
            return
        }

        if idleTimerDisabledBeforePlayback == nil {
            idleTimerDisabledBeforePlayback = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func restoreIdleTimer() {
        guard let previousValue = idleTimerDisabledBeforePlayback else { return }
        UIApplication.shared.isIdleTimerDisabled = previousValue
        idleTimerDisabledBeforePlayback = nil
    }

    static func shouldKeepScreenAwake(for state: MPVPlaybackState) -> Bool {
        switch state {
        case .buffering, .readyToPlay, .bufferFinished:
            true
        case .paused, .playedToTheEnd, .error:
            false
        }
    }
}
