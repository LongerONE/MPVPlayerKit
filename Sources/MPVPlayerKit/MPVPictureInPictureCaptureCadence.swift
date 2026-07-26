import Foundation

/// Chooses how often a Picture in Picture frame is captured.
///
/// The inline player renders at the video's own frame rate. Picture in Picture
/// is fed by `screenshot-raw`, so the cadence follows the same frame rate up to
/// a ceiling, and backs off when a capture costs more than the interval it is
/// scheduled at. A paused player only needs occasional captures: they keep the
/// window in sync after a seek without spending CPU on identical frames.
enum MPVPictureInPictureCaptureCadence {
    static let fallbackVideoFrameRate: Double = 25
    static let minimumPlayingInterval: TimeInterval = 1.0 / 30
    static let maximumPlayingInterval: TimeInterval = 0.2
    static let pausedInterval: TimeInterval = 0.5
    /// Headroom over the measured capture cost. A factor of two keeps capture
    /// work at about half of the wall clock, leaving the rest for playback.
    static let captureCostFactor: Double = 2.0
    static let rescheduleTolerance: TimeInterval = 0.008
    /// Frames between capture cost reports in debug builds.
    static let statisticsInterval: UInt64 = 60
    /// Weight of a new sample in the exponential moving average.
    static let captureDurationSmoothing: Double = 0.25

    static func interval(
        videoFrameRate: Double,
        averageCaptureDuration: TimeInterval,
        isPlaying: Bool
    ) -> TimeInterval {
        guard isPlaying else { return pausedInterval }
        let frameRate = videoFrameRate.isFinite && videoFrameRate > 0
            ? videoFrameRate
            : fallbackVideoFrameRate
        let frameInterval = 1 / frameRate
        let costInterval = averageCaptureDuration.isFinite && averageCaptureDuration > 0
            ? averageCaptureDuration * captureCostFactor
            : 0
        let interval = max(frameInterval, costInterval)
        return min(max(interval, minimumPlayingInterval), maximumPlayingInterval)
    }

    /// Tolerance between the captured frame position and the player position.
    static let pausedFrameTolerance: TimeInterval = 0.05

    /// A paused player keeps producing the same frame. Capturing it again costs
    /// a full screenshot readback for no visible change, so captures resume
    /// only until the window catches up with a seek.
    static func shouldSkipPausedCapture(
        isPlaying: Bool,
        isWaitingForStart: Bool,
        lastCapturedPresentationTime: TimeInterval?,
        currentTime: TimeInterval
    ) -> Bool {
        guard isPlaying == false,
              isWaitingForStart == false,
              let lastCapturedPresentationTime
        else { return false }
        return abs(lastCapturedPresentationTime - currentTime) <= pausedFrameTolerance
    }

    static func shouldReschedule(
        currentInterval: TimeInterval?,
        nextInterval: TimeInterval
    ) -> Bool {
        guard let currentInterval else { return true }
        return abs(currentInterval - nextInterval) > rescheduleTolerance
    }

    /// A sample this far above the running average is treated as a one-off.
    static let captureDurationOutlierFactor: Double = 4
    /// Samples below this are never treated as outliers.
    static let captureDurationOutlierFloor: TimeInterval = 0.5

    /// Rejects one-off costs, such as the seconds MPV can spend compiling its
    /// render pipeline on the first frame, which would otherwise hold the
    /// cadence at its slowest for several seconds.
    static func averageCaptureDuration(
        previousAverage: TimeInterval,
        sample: TimeInterval
    ) -> TimeInterval {
        guard sample.isFinite, sample > 0 else { return previousAverage }
        guard previousAverage.isFinite, previousAverage > 0 else {
            return min(sample, captureDurationOutlierFloor)
        }
        let outlierThreshold = max(
            captureDurationOutlierFloor,
            previousAverage * captureDurationOutlierFactor
        )
        guard sample <= outlierThreshold else { return previousAverage }
        return previousAverage * (1 - captureDurationSmoothing)
            + sample * captureDurationSmoothing
    }

    static func dispatchInterval(_ interval: TimeInterval) -> DispatchTimeInterval {
        .milliseconds(max(1, Int((interval * 1000).rounded())))
    }
}
