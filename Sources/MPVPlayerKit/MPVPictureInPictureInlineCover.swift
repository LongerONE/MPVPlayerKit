import UIKit

/// Tracks the inline presentation state independently of AVKit so lifecycle
/// transitions can be verified without requiring Picture in Picture support.
struct MPVPictureInPictureInlineCoverLifecycle {
    enum State: Equatable {
        case hidden
        case starting
        case visible
    }

    private(set) var state: State = .hidden

    mutating func requestStart() {
        state = .starting
    }

    mutating func didStart() -> Bool {
        guard state == .starting else { return false }
        state = .visible
        return true
    }

    mutating func end() -> Bool {
        let wasVisible = state == .visible
        state = .hidden
        return wasVisible
    }
}

/// An opaque cover over the inline player while system Picture in Picture owns
/// the visible video. It never alters the MPV-backed CAMetalLayer.
@MainActor
final class MPVPictureInPictureInlineCover {
    private let view = UIView()

    init() {
        view.backgroundColor = .black
        view.isOpaque = true
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = "MPVPlayerView.pictureInPictureInlineCover"
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    func show(over playerView: UIView) {
        if view.superview !== playerView {
            view.removeFromSuperview()
            playerView.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
                view.topAnchor.constraint(equalTo: playerView.topAnchor),
                view.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
            ])
        }
        playerView.bringSubviewToFront(view)
    }

    func hide() {
        view.removeFromSuperview()
    }

    func bringToFrontIfVisible(over playerView: UIView) {
        guard view.superview === playerView else { return }
        playerView.bringSubviewToFront(view)
    }
}
