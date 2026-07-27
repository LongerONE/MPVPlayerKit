import UIKit

/// Moves the player view between its inline position and the Picture in
/// Picture container, and puts a stand-in view in its place while it is away.
///
/// Hosting the real view is what keeps Picture in Picture on the same renderer
/// as inline playback: the MPV Metal layer, and with it `gpu-next`, libplacebo
/// tone mapping and Dolby Vision, moves along with the view instead of being
/// re-encoded into sample buffers.
@MainActor
final class MPVPictureInPictureViewPlacement {
    private weak var playerView: MPVPlayerView?
    private weak var originalSuperview: UIView?
    private let originalSubviewIndex: Int
    /// The anchor AVKit tracks. It stays in the inline hierarchy for the whole
    /// lifetime of the placement, so the system keeps a stable source rect even
    /// while the player view itself is in the Picture in Picture window.
    let sourceView = UIView()
    private var originalConstraints: [NSLayoutConstraint] = []
    private var sourceConstraints: [NSLayoutConstraint] = []
    private var pictureInPictureConstraints: [NSLayoutConstraint] = []
    private var restoredFullscreenConstraints: [NSLayoutConstraint] = []
    private(set) var isPlayerInPictureInPictureContainer = false

    init?(playerView: MPVPlayerView) {
        guard let superview = playerView.superview,
              let index = superview.subviews.firstIndex(of: playerView)
        else {
            return nil
        }

        self.playerView = playerView
        originalSuperview = superview
        originalSubviewIndex = index

        sourceView.backgroundColor = .clear
        sourceView.isUserInteractionEnabled = false
        sourceView.accessibilityElementsHidden = true
        installSourceView(below: playerView, in: superview, at: index)
    }

    /// Returns whether the player view actually moved, so the caller can
    /// re-synchronize the renderer with its new size.
    @discardableResult
    func movePlayer(to containerView: UIView) -> Bool {
        guard isPlayerInPictureInPictureContainer == false,
              let playerView
        else {
            return false
        }

        restoredFullscreenConstraints.forEach { $0.isActive = false }
        restoredFullscreenConstraints.removeAll()
        originalConstraints.forEach { $0.isActive = false }
        playerView.removeFromSuperview()
        playerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(playerView)
        pictureInPictureConstraints = [
            playerView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: containerView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(pictureInPictureConstraints)
        // `layoutIfNeeded()` synchronously calls the Picture in Picture
        // content controller's `viewDidLayoutSubviews()`. Mark the move first
        // so that callback cannot enter this method again while the hierarchy
        // is still being updated.
        isPlayerInPictureInPictureContainer = true
        containerView.layoutIfNeeded()
        return true
    }

    @discardableResult
    func restorePlayer() -> Bool {
        guard isPlayerInPictureInPictureContainer,
              let playerView,
              let originalSuperview
        else {
            return false
        }

        pictureInPictureConstraints.forEach { $0.isActive = false }
        pictureInPictureConstraints.removeAll()
        playerView.removeFromSuperview()
        let insertionIndex = min(originalSubviewIndex, originalSuperview.subviews.count)
        originalSuperview.insertSubview(playerView, at: insertionIndex)
        // A PiP return may restore the old, PiP-sized frame before the host
        // gets another layout pass. Do not wait for a rotation to repair it:
        // the renderer always returns as the full inline playback surface.
        originalConstraints.forEach { $0.isActive = false }
        playerView.translatesAutoresizingMaskIntoConstraints = false
        restoredFullscreenConstraints = [
            playerView.leadingAnchor.constraint(equalTo: originalSuperview.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: originalSuperview.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: originalSuperview.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: originalSuperview.bottomAnchor),
        ]
        NSLayoutConstraint.activate(restoredFullscreenConstraints)
        originalSuperview.layoutIfNeeded()
        isPlayerInPictureInPictureContainer = false
        return true
    }

    func tearDown() {
        _ = restorePlayer()
        sourceConstraints.forEach { $0.isActive = false }
        sourceConstraints.removeAll()
        sourceView.removeFromSuperview()
    }

    /// Mirrors the player view's layout onto the stand-in, so the inline layout
    /// does not collapse while the player view is hosted elsewhere.
    private func installSourceView(
        below playerView: MPVPlayerView,
        in superview: UIView,
        at index: Int
    ) {
        sourceView.frame = playerView.frame
        sourceView.autoresizingMask = playerView.autoresizingMask
        sourceView.translatesAutoresizingMaskIntoConstraints =
            playerView.translatesAutoresizingMaskIntoConstraints
        superview.insertSubview(sourceView, at: min(index + 1, superview.subviews.count))

        guard playerView.translatesAutoresizingMaskIntoConstraints == false else {
            return
        }

        originalConstraints = constraintsReferencing(playerView, from: superview)
        sourceConstraints = originalConstraints.compactMap {
            replacement(for: $0, replacing: playerView, with: sourceView)
        }
        NSLayoutConstraint.activate(sourceConstraints)
    }

    private func constraintsReferencing(
        _ view: UIView,
        from superview: UIView
    ) -> [NSLayoutConstraint] {
        var constraints: [NSLayoutConstraint] = []
        var current: UIView? = superview
        while let container = current {
            constraints += container.constraints.filter {
                ($0.firstItem as AnyObject?) === view ||
                    ($0.secondItem as AnyObject?) === view
            }
            current = container.superview
        }
        constraints += view.constraints
        constraints = constraints.filter { constraint in
            let firstItem = constraint.firstItem as AnyObject?
            let secondItem = constraint.secondItem as AnyObject?
            guard firstItem === view || secondItem === view else { return false }
            let otherItem = firstItem === view ? constraint.secondItem : constraint.firstItem
            guard let otherView = owningView(for: otherItem) else { return true }
            return otherView !== view && otherView.isDescendant(of: view) == false
        }
        return Array(Set(constraints)).filter(\.isActive)
    }

    private func owningView(for item: Any?) -> UIView? {
        if let view = item as? UIView {
            return view
        }
        if let guide = item as? UILayoutGuide {
            return guide.owningView
        }
        return nil
    }

    private func replacement(
        for constraint: NSLayoutConstraint,
        replacing playerView: MPVPlayerView,
        with sourceView: UIView
    ) -> NSLayoutConstraint? {
        let firstItem = constraint.firstItem as AnyObject?
        let secondItem = constraint.secondItem as AnyObject?
        let replacement = NSLayoutConstraint(
            item: firstItem === playerView ? sourceView : (constraint.firstItem as AnyObject),
            attribute: constraint.firstAttribute,
            relatedBy: constraint.relation,
            toItem: secondItem === playerView ? sourceView : (constraint.secondItem as AnyObject?),
            attribute: constraint.secondAttribute,
            multiplier: constraint.multiplier,
            constant: constraint.constant
        )
        replacement.priority = constraint.priority
        replacement.identifier = constraint.identifier
        return replacement
    }
}
