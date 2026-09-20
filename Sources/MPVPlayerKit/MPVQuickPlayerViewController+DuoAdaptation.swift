import UIKit

// MARK: - iPhone Duo adaptation surface (Xcode 27.0 SDK compatible)

// iOS 27.1 types (UIHingeInteraction / UIView.ReservedRegion /
// UIVerticalBarBehavior / UIArrangementViewController) are not available when
// building with Xcode 27.0 / iOS 27.0 SDK. This file uses only APIs that exist
// on that SDK so Temby / LuWu / MPVPlayerKit can compile on the stable toolchain.
// Hosts on Xcode 27.1 can still drive compact chrome via `setHingeCompactChrome(_:)`.

extension MPVQuickPlayerViewController {
    /// Marks hinge observation as attempted (API hook reserved for Xcode 27.1 SDK).
    var isDuoHingeObservationInstalled: Bool {
        get { hingeInteraction != nil }
        set { hingeInteraction = newValue ? true as AnyObject : nil }
    }

    /// Install hinge observation when the platform exposes hinge APIs.
    /// Safe no-op on Xcode 27.0 SDK / non-Duo devices.
    func installDuoHingeObservationIfNeeded() {
        guard hingeInteraction == nil else { return }
        // Placeholder retained so future SDK can attach UIHingeInteraction without
        // changing call sites. On iOS 27.0 SDK this remains a no-op.
        hingeInteraction = true as AnyObject
    }

    /// Hosts (or a future 27.1 hinge observer) toggle compact playback chrome.
    public func setHingeCompactChrome(_ compact: Bool) {
        guard isHingeCompact != compact else { return }
        isHingeCompact = compact
        if isViewLoaded {
            updatePlaybackControlSafeAreaInsets()
        }
    }

    /// Horizontal padding so custom chrome clears fold-like gaps.
    /// Without ReservedRegion APIs, compact hinge mode adds symmetric edge padding.
    func duoReservedHorizontalPadding() -> (leading: CGFloat, trailing: CGFloat) {
        guard isViewLoaded else { return (0, 0) }
        guard isHingeCompact else { return (0, 0) }
        return (12, 12)
    }
}

// MARK: - Size-class dual-pane container (Arrangement API fallback)

/// Size-class driven primary/secondary container used when `UIArrangementViewController`
/// is unavailable (Xcode 27.0 SDK). Regular+wide → side-by-side; regular+tall → stacked;
/// compact → primary only.
@MainActor
public final class MPVPlayerDualPaneContainer: UIViewController {
    public let primaryViewController: UIViewController
    public let secondaryViewController: UIViewController
    /// When true, never stack vertically — hide secondary in compact/tall layouts.
    public var horizontalOnly: Bool
    /// When true, secondary overlays primary instead of taking a split column.
    public var prefersOverlay: Bool

    private let primaryHost = UIView()
    private let secondaryHost = UIView()
    private var didInstallChildren = false

    public init(
        primary: UIViewController,
        secondary: UIViewController,
        horizontalOnly: Bool = false,
        prefersOverlay: Bool = false
    ) {
        self.primaryViewController = primary
        self.secondaryViewController = secondary
        self.horizontalOnly = horizontalOnly
        self.prefersOverlay = prefersOverlay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        primaryHost.translatesAutoresizingMaskIntoConstraints = false
        secondaryHost.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(primaryHost)
        view.addSubview(secondaryHost)
        installChildrenIfNeeded()
        applyLayoutForCurrentTraits()
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        applyLayoutForCurrentTraits()
    }

    public override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.applyLayoutForCurrentTraits()
        })
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass
            || previousTraitCollection?.verticalSizeClass != traitCollection.verticalSizeClass else {
            return
        }
        applyLayoutForCurrentTraits()
    }

    private func installChildrenIfNeeded() {
        guard didInstallChildren == false else { return }
        didInstallChildren = true
        addChild(primaryViewController)
        primaryHost.addSubview(primaryViewController.view)
        primaryViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            primaryViewController.view.leadingAnchor.constraint(equalTo: primaryHost.leadingAnchor),
            primaryViewController.view.trailingAnchor.constraint(equalTo: primaryHost.trailingAnchor),
            primaryViewController.view.topAnchor.constraint(equalTo: primaryHost.topAnchor),
            primaryViewController.view.bottomAnchor.constraint(equalTo: primaryHost.bottomAnchor),
        ])
        primaryViewController.didMove(toParent: self)

        addChild(secondaryViewController)
        secondaryHost.addSubview(secondaryViewController.view)
        secondaryViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            secondaryViewController.view.leadingAnchor.constraint(equalTo: secondaryHost.leadingAnchor),
            secondaryViewController.view.trailingAnchor.constraint(equalTo: secondaryHost.trailingAnchor),
            secondaryViewController.view.topAnchor.constraint(equalTo: secondaryHost.topAnchor),
            secondaryViewController.view.bottomAnchor.constraint(equalTo: secondaryHost.bottomAnchor),
        ])
        secondaryViewController.didMove(toParent: self)
    }

    private func applyLayoutForCurrentTraits() {
        view.layoutIfNeeded()
        primaryHost.removeFromSuperview()
        secondaryHost.removeFromSuperview()
        view.addSubview(primaryHost)
        view.addSubview(secondaryHost)

        let bounds = view.bounds
        let isRegular = traitCollection.horizontalSizeClass == .regular
        let isWide = bounds.width >= bounds.height
        let safe = view.safeAreaLayoutGuide

        let showSideBySide = isRegular && isWide
        let showStacked = isRegular && isWide == false && horizontalOnly == false
        let showOverlay = prefersOverlay && isRegular

        if showOverlay {
            NSLayoutConstraint.activate([
                primaryHost.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                primaryHost.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                primaryHost.topAnchor.constraint(equalTo: safe.topAnchor),
                primaryHost.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
                secondaryHost.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                secondaryHost.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                secondaryHost.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
                secondaryHost.heightAnchor.constraint(equalTo: safe.heightAnchor, multiplier: 0.35),
            ])
        } else if showSideBySide {
            NSLayoutConstraint.activate([
                primaryHost.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                primaryHost.topAnchor.constraint(equalTo: safe.topAnchor),
                primaryHost.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
                primaryHost.widthAnchor.constraint(equalTo: safe.widthAnchor, multiplier: 0.5),
                secondaryHost.leadingAnchor.constraint(equalTo: primaryHost.trailingAnchor),
                secondaryHost.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                secondaryHost.topAnchor.constraint(equalTo: safe.topAnchor),
                secondaryHost.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            ])
        } else if showStacked {
            NSLayoutConstraint.activate([
                primaryHost.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                primaryHost.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                primaryHost.topAnchor.constraint(equalTo: safe.topAnchor),
                primaryHost.heightAnchor.constraint(equalTo: safe.heightAnchor, multiplier: 0.6),
                secondaryHost.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                secondaryHost.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                secondaryHost.topAnchor.constraint(equalTo: primaryHost.bottomAnchor),
                secondaryHost.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            ])
        } else {
            // Compact or single-view: primary fills; secondary hidden but retained.
            NSLayoutConstraint.activate([
                primaryHost.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                primaryHost.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                primaryHost.topAnchor.constraint(equalTo: safe.topAnchor),
                primaryHost.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            ])
            secondaryHost.isHidden = true
            return
        }

        secondaryHost.isHidden = false
    }
}

/// Factory for dual-pane player-adjacent UI. On Xcode 27.1 SDK hosts may later
/// swap to `UIArrangementViewController`; call sites stay source-compatible.
public enum MPVPlayerArrangementFactory {
    @MainActor
    public static func makeSplitContainer(
        primary: UIViewController,
        secondary: UIViewController,
        horizontalOnly: Bool
    ) -> UIViewController {
        MPVPlayerDualPaneContainer(
            primary: primary,
            secondary: secondary,
            horizontalOnly: horizontalOnly,
            prefersOverlay: false
        )
    }

    @MainActor
    public static func makeOverlayContainer(
        primary: UIViewController,
        secondary: UIViewController
    ) -> UIViewController {
        MPVPlayerDualPaneContainer(
            primary: primary,
            secondary: secondary,
            horizontalOnly: false,
            prefersOverlay: true
        )
    }
}
