import UIKit

// MARK: - iPhone Duo (iOS 27.1) adaptation surface for the quick player.

extension MPVQuickPlayerViewController {
    /// Install hinge observation when running on iPhone Duo / iOS 27.1+.
    /// Layout still prefers reserved regions + safe area; hinge only densifies chrome.
    func installDuoHingeObservationIfNeeded() {
        guard #available(iOS 27.1, *) else { return }
        guard hingeInteraction == nil else { return }
        let interaction = UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            let compact = update.hinge?.status == .partiallyOpen
            if compact != isHingeCompact {
                isHingeCompact = compact
                updatePlaybackControlSafeAreaInsets()
            }
        }
        view.addInteraction(interaction)
        hingeInteraction = interaction
    }

    /// Horizontal padding needed so custom chrome clears active reserved regions (fold / camera).
    func duoReservedHorizontalPadding() -> (leading: CGFloat, trailing: CGFloat) {
        guard #available(iOS 27.1, *) else { return (0, 0) }
        guard isViewLoaded else { return (0, 0) }
        let regions = view.reservedRegions(kind: .division, options: .includeInactive)
            + view.reservedRegions(kind: .occlusion, options: .includeInactive)
        let active = regions.filter(\.isActive)
        guard active.isEmpty == false else { return (0, 0) }

        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return (0, 0) }
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
        let midX = bounds.midX

        for region in active {
            let frame = region.frame
            // Central division (hinge): keep edge chrome, slightly enlarge for reachability.
            if frame.minX < midX, frame.maxX > midX {
                leading = max(leading, 12)
                trailing = max(trailing, 12)
                continue
            }
            // Occlusion near leading / trailing edges pushes controls inward.
            if frame.maxX <= midX {
                leading = max(leading, max(0, frame.maxX + region.margins.left))
            } else if frame.minX >= midX {
                trailing = max(trailing, max(0, bounds.maxX - frame.minX + region.margins.right))
            }
        }
        return (leading, trailing)
    }
}

// MARK: - Fullscreen player prefers horizontal custom chrome (system vertical bar disabled).

extension MPVQuickPlayerViewController {
    @available(iOS 27.1, *)
    public override var preferredVerticalBarBehavior: UIVerticalBarBehavior {
        // Fullscreen video player: custom chrome owns the edges; system bars stay horizontal.
        .disabled
    }
}

// MARK: - Arrangement helpers for hosts that want iOS 27.1 split/overlay containers.

public enum MPVPlayerArrangementFactory {
    /// Builds a system arrangement container for primary/secondary player-adjacent UI.
    /// Only available on iOS 27.1+ (iPhone Duo SDK).
    @available(iOS 27.1, *)
    @MainActor
    public static func makeSplitContainer(
        primary: UIViewController,
        secondary: UIViewController,
        horizontalOnly: Bool
    ) -> UIArrangementViewController {
        let container = UIArrangementViewController()
        container.setViewController(primary, for: .primary)
        container.setViewController(secondary, for: .secondary)
        if horizontalOnly {
            container.updateArrangement(UISplitArrangement().axes(.horizontal))
        } else {
            container.updateArrangement(.split)
        }
        return container
    }

    @available(iOS 27.1, *)
    @MainActor
    public static func makeOverlayContainer(
        primary: UIViewController,
        secondary: UIViewController
    ) -> UIArrangementViewController {
        let container = UIArrangementViewController()
        container.setViewController(primary, for: .primary)
        container.setViewController(secondary, for: .secondary)
        container.updateArrangement(.overlay)
        return container
    }
}
