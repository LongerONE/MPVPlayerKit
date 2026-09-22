import UIKit

@objc public enum MPVVideoDisplayMode: Int, Sendable {
    case fit
    case fill
    case custom
}

enum MPVContentModeSnapshot {
    case fit
    case fill
    case custom(scale: CGFloat)

    init(contentModeRawValue: Int) {
        self = contentModeRawValue == UIView.ContentMode.scaleAspectFill.rawValue ? .fill : .fit
    }

    init(displayMode: MPVVideoDisplayMode, customScale: CGFloat) {
        switch displayMode {
        case .fit: self = .fit
        case .fill: self = .fill
        case .custom: self = .custom(scale: min(max(customScale, 0.5), 3.0))
        }
    }

    /// `video-zoom` uses a base-2 logarithm. Applying zoom inside libmpv keeps
    /// text subtitles in the OSD window while bitmap subtitles stay in video
    /// coordinates.
    var nativeVideoZoom: Double {
        guard case let .custom(scale) = self, scale > 0 else { return 0.0 }
        return log2(Double(scale))
    }
}

struct MPVDisplayModeState {
    /// QuickPlayer defaults to fill so letterbox bars stay hidden.
    var mode: MPVVideoDisplayMode = .fill
    var scale: CGFloat = 1.0
}

extension MPVPlayerView {
    public var videoDisplayMode: MPVVideoDisplayMode {
        get { displayModeState.mode }
        set {
            guard displayModeState.mode != newValue else { return }
            displayModeState.mode = newValue
            applyVideoDisplayMode()
        }
    }

    @objc public var videoDisplayModeRawValue: Int {
        get { videoDisplayMode.rawValue }
        set {
            guard let mode = MPVVideoDisplayMode(rawValue: newValue) else { return }
            videoDisplayMode = mode
        }
    }

    @objc public var customVideoScale: Double {
        get { Double(displayModeState.scale) }
        set {
            let scale = CGFloat(newValue)
            guard scale.isFinite else { return }
            let normalizedScale = min(max(scale, 0.5), 3.0)
            guard abs(displayModeState.scale - normalizedScale) > 0.0001 else { return }
            displayModeState.scale = normalizedScale
            guard videoDisplayMode == .custom else { return }
            applyVideoDisplayMode()
        }
    }

    @objc public func resetCustomVideoScale() {
        customVideoScale = 1.0
    }
}
