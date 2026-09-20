import UIKit

/// Extra chrome insets beyond the view's safe area (side bar channel, etc.).
public struct MPVPlayerChromeInsets: Sendable, Equatable {
    public var leading: CGFloat
    public var trailing: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat

    public init(leading: CGFloat = 0, trailing: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0) {
        self.leading = leading
        self.trailing = trailing
        self.top = top
        self.bottom = bottom
    }

    public static let zero = MPVPlayerChromeInsets()
}

/// Orientation behavior for ``MPVQuickPlayerViewController`` on resizable displays (iPhone Duo).
public enum MPVOrientationPolicy: Sendable, Equatable {
    /// Follow the current pose and size class. Hides the force-landscape control.
    case followPose
    /// Default follows pose; the force-landscape button stays available when the system allows landscape.
    case optionalForceLandscape
}
