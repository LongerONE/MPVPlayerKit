import UIKit

// MARK: - 基于实际保留区域的播放布局

extension MPVQuickPlayerViewController {
    func installDuoHingeObservationIfNeeded() {
        guard hingeInteraction == nil else { return }
        if #available(iOS 27.1, *) {
            let interaction = UIHingeInteraction { [weak self] _, _ in
                guard let self else { return }
                view.setNeedsLayout()
            }
            hingeInteraction = interaction
            view.addInteraction(interaction)
        }
    }

    public func setHingeCompactChrome(_ compact: Bool) {
        guard isHingeCompact != compact else { return }
        isHingeCompact = compact
        viewIfLoaded?.setNeedsLayout()
    }

    var hasFoldingDisplay: Bool {
        guard isViewLoaded else { return false }
        if #available(iOS 27.1, *) {
            return !contentView.reservedRegions(kind: .division, options: .includeInactive).isEmpty
        }
        return false
    }

    func duoRegions() -> MPVDuoLayout.Regions? {
        guard isViewLoaded else { return nil }
        if #available(iOS 27.1, *) {
            let insets = Self.playerOrientationSafeAreaInsets(
                rootBounds: view.bounds, rootSafeAreaInsets: view.safeAreaInsets,
                usesManualLandscape: isUsingManualLandscape && isLandscapeForced
            )
            return MPVDuoLayout.regions(
                in: contentView.bounds.inset(by: insets),
                divisions: contentView.reservedRegions(kind: .division).map(\.frame)
            )
        }
        return nil
    }

    func updateDuoRegions(_ regions: MPVDuoLayout.Regions?) {
        let bounds = contentView.bounds
        let media = regions?.media ?? bounds
        let controls = regions?.controls ?? bounds
        let mediaValues = [media.minX, media.maxX - bounds.width, media.minY, media.maxY - bounds.height]
        let topValues = [controls.minX, controls.maxX - bounds.width, controls.minY]
        let controlValues = [controls.minX, controls.maxX - bounds.width, controls.maxY - bounds.height]
        for (constraints, values) in [(duoMediaConstraints, mediaValues), (duoTopBarConstraints, topValues), (duoControlsConstraints, controlValues)] {
            for (constraint, value) in zip(constraints, values) where constraint.constant != value {
                constraint.constant = value
            }
        }
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
