import CoreGraphics

enum MPVPictureInPictureContentSize {
    static let fallback = CGSize(width: 16, height: 9)

    static func resolve(videoDisplaySize: CGSize) -> CGSize {
        guard videoDisplaySize.width > 0, videoDisplaySize.height > 0,
              videoDisplaySize.width.isFinite, videoDisplaySize.height.isFinite
        else { return fallback }
        return videoDisplaySize
    }
}

enum MPVPictureInPictureStartCancellationPolicy {
    static func shouldStopSystemController(isStarting: Bool) -> Bool { isStarting }

    static func shouldPostInactiveState(
        hasPostedActiveState: Bool,
        isStartCancellationRequested: Bool
    ) -> Bool { hasPostedActiveState && isStartCancellationRequested == false }
}

enum MPVPictureInPictureFrameUpdatePolicy {
    static func shouldKeepUpdating(
        isActive: Bool,
        isStarting: Bool,
        isWaitingForStart: Bool
    ) -> Bool { isActive || isStarting || isWaitingForStart }
}

enum MPVPictureInPictureTeardownPolicy {
    static func shouldStartFrameUpdates(isTearingDown: Bool) -> Bool { isTearingDown == false }

    static func shouldResumeAutomaticReadinessUpdates(
        allowsAutomaticStartFromInline: Bool,
        isTearingDown: Bool
    ) -> Bool { allowsAutomaticStartFromInline && isTearingDown == false }

    static func shouldStartSystemController(
        isStartCancellationRequested: Bool,
        isTearingDown: Bool
    ) -> Bool { isStartCancellationRequested == false && isTearingDown == false }
}
