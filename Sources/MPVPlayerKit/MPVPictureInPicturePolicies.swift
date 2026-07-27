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
    /// The content view controller appears before the system reports the
    /// window as active, and it also appears on a start that is already being
    /// cancelled. Moving the player view then would strand it in a window that
    /// is about to close.
    static func shouldMovePlayer(
        isStarting: Bool,
        isActive: Bool,
        isCancellationRequested: Bool,
        isStopping: Bool
    ) -> Bool {
        isCancellationRequested == false
            && isStopping == false
            && (isStarting || isActive)
    }

    static func shouldPostInactiveState(
        hasPostedActiveState: Bool,
        isStartCancellationRequested: Bool
    ) -> Bool { hasPostedActiveState && isStartCancellationRequested == false }
}

enum MPVPictureInPictureTeardownPolicy {
    static func shouldStartSystemController(
        isStartCancellationRequested: Bool,
        isTearingDown: Bool
    ) -> Bool { isStartCancellationRequested == false && isTearingDown == false }
}
