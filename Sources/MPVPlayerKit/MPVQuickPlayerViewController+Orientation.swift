import UIKit

extension MPVQuickPlayerViewController {
    public override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        isDisplayTransitionInProgress = true
        loadingIndicator.stopAnimating()
        player.playbackView.beginDisplayGeometryTransition()

        let synchronizeMenuLayout = { [weak self] in
            guard let self else { return }
            view.layoutIfNeeded()
            layoutOrientationContentView()
            updatePlaybackControlSafeAreaInsets()
            actionSheetOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
            cacheSettingsOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
            contentView.layoutIfNeeded()
        }
        coordinator.animate(
            alongsideTransition: { _ in synchronizeMenuLayout() },
            completion: { [weak self] _ in
                synchronizeMenuLayout()
                guard let self else { return }
                player.playbackView.endDisplayGeometryTransition()
                isDisplayTransitionInProgress = false
                if Self.shouldShowLoading(for: playbackState) {
                    loadingIndicator.startAnimating()
                }
            }
        )
    }

    static var applicationSupportsLandscape: Bool {
        let deviceSpecificKey = UIDevice.current.userInterfaceIdiom == .pad
            ? "UISupportedInterfaceOrientations~ipad"
            : "UISupportedInterfaceOrientations"
        let orientationNames = Bundle.main.object(forInfoDictionaryKey: deviceSpecificKey) as? [String]
            ?? Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String]
        return supportsLandscape(orientationNames: orientationNames)
    }

    static func supportsLandscape(orientationNames: [String]?) -> Bool {
        orientationNames?.contains {
            $0 == "UIInterfaceOrientationLandscapeLeft"
                || $0 == "UIInterfaceOrientationLandscapeRight"
        } ?? false
    }

    /// Locks the quick player to landscape-right or restores automatic rotation.
    public func setForceLandscape(_ forced: Bool) {
        guard isLandscapeForced != forced else {
            applyPreferredOrientationIfNeeded()
            return
        }

        isLandscapeForced = forced
        isUsingManualLandscape = forced && Self.applicationSupportsLandscape == false
        updateOrientationButton()
        invalidateSupportedInterfaceOrientations()
        if isUsingManualLandscape {
            applyManualLandscape()
        } else {
            restoreManualLandscape()
            requestInterfaceOrientation(forced ? .landscapeRight : .portrait)
        }
    }

    @objc func toggleForcedLandscape() {
        setForceLandscape(isLandscapeForced == false)
    }

    func applyPreferredOrientationIfNeeded() {
        updateOrientationButton()
        guard isLandscapeForced else { return }
        isUsingManualLandscape = Self.applicationSupportsLandscape == false
        invalidateSupportedInterfaceOrientations()
        if isUsingManualLandscape {
            applyManualLandscape()
        } else {
            requestInterfaceOrientation(.landscapeRight)
        }
    }

    func updateOrientationButton() {
        guard isViewLoaded else { return }
        orientationButton.isSelected = isLandscapeForced
        orientationButton.tintColor = isLandscapeForced ? .systemBlue : .white
        orientationButton.accessibilityValue = mpvLocalized(
            isLandscapeForced ? "accessibility.enabled" : "accessibility.disabled"
        )
    }

    private func requestInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard let windowScene = view.window?.windowScene else { return }

        if #available(iOS 16.0, *) {
            let mask: UIInterfaceOrientationMask = orientation == .portrait ? .portrait : .landscapeRight
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] _ in
                guard orientation != .portrait else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, isLandscapeForced else { return }
                    isUsingManualLandscape = true
                    invalidateSupportedInterfaceOrientations()
                    applyManualLandscape()
                }
            }
        } else {
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private func invalidateSupportedInterfaceOrientations() {
        guard #available(iOS 16.0, *) else { return }
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    func layoutOrientationContentView() {
        let rootBounds = view.bounds
        let shouldRotate = isUsingManualLandscape
            && isLandscapeForced
            && rootBounds.height > rootBounds.width
        let targetSize = shouldRotate
            ? CGSize(width: rootBounds.height, height: rootBounds.width)
            : rootBounds.size
        let targetBounds = CGRect(origin: .zero, size: targetSize)
        let targetCenter = CGPoint(x: rootBounds.midX, y: rootBounds.midY)
        let targetTransform = shouldRotate
            ? CGAffineTransform(rotationAngle: .pi / 2)
            : .identity

        guard contentView.bounds != targetBounds
                || contentView.center != targetCenter
                || contentView.transform != targetTransform else { return }

        UIView.performWithoutAnimation {
            contentView.bounds = targetBounds
            contentView.center = targetCenter
            contentView.transform = targetTransform
            contentView.layoutIfNeeded()
        }
        actionSheetOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
        cacheSettingsOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
    }

    /// Safe-area insets expressed in the coordinate system of `contentView`.
    /// Manual landscape rotates the content view while its host remains portrait,
    /// so the root's four edges need to be mapped before Auto Layout runs.
    func playerOrientationSafeAreaInsets() -> UIEdgeInsets {
        Self.playerOrientationSafeAreaInsets(
            rootBounds: view.bounds,
            rootSafeAreaInsets: view.safeAreaInsets,
            usesManualLandscape: isUsingManualLandscape && isLandscapeForced
        )
    }

    static func playerOrientationSafeAreaInsets(
        rootBounds: CGRect,
        rootSafeAreaInsets: UIEdgeInsets,
        usesManualLandscape: Bool
    ) -> UIEdgeInsets {
        guard usesManualLandscape && rootBounds.height > rootBounds.width else {
            return rootSafeAreaInsets
        }
        return UIEdgeInsets(
            top: rootSafeAreaInsets.right,
            left: rootSafeAreaInsets.top,
            bottom: rootSafeAreaInsets.left,
            right: rootSafeAreaInsets.bottom
        )
    }

    func presentInPlayerOrientation(_ controller: UIViewController, animated: Bool = true) {
        orientationSynchronizedPresentedViewController = controller
        present(controller, animated: animated) { [weak self, weak controller] in
            guard let self, let controller else { return }
            layoutPresentedViewControllerInPlayerOrientation(controller)
        }
    }

    /// Keeps custom presentation controllers aligned when asynchronous geometry updates change root bounds.
    func layoutPresentedViewControllerInPlayerOrientation(
        _ controller: UIViewController? = nil
    ) {
        guard let controller = controller ?? orientationSynchronizedPresentedViewController else { return }
        guard presentedViewController === controller, let presentedView = controller.view else {
            if controller.presentingViewController == nil {
                orientationSynchronizedPresentedViewController = nil
            }
            return
        }

        // UIAlertController owns a private view hierarchy and lays out its action sheet
        // in the host interface orientation. Changing its bounds or transform after
        // presentation makes its internal constraints use the wrong coordinate space,
        // which clips long action titles in manual landscape mode.
        guard Self.shouldApplyManualLandscapeTransform(to: controller) else { return }

        Self.layoutPresentedView(
            presentedView,
            rootBounds: view.bounds,
            usesManualLandscape: isUsingManualLandscape && isLandscapeForced
        )
    }

    static func shouldApplyManualLandscapeTransform(to controller: UIViewController) -> Bool {
        controller is UIAlertController == false
    }

    static func layoutPresentedView(
        _ presentedView: UIView,
        rootBounds: CGRect,
        usesManualLandscape: Bool
    ) {
        let shouldRotate = usesManualLandscape && rootBounds.height > rootBounds.width
        let targetBounds = CGRect(
            origin: .zero,
            size: shouldRotate
                ? CGSize(width: rootBounds.height, height: rootBounds.width)
                : rootBounds.size
        )
        let targetCenter = CGPoint(x: rootBounds.midX, y: rootBounds.midY)
        let targetTransform = shouldRotate
            ? CGAffineTransform(rotationAngle: .pi / 2)
            : .identity

        guard presentedView.bounds != targetBounds
                || presentedView.center != targetCenter
                || presentedView.transform != targetTransform else { return }

        UIView.performWithoutAnimation {
            presentedView.bounds = targetBounds
            presentedView.center = targetCenter
            presentedView.transform = targetTransform
            presentedView.layoutIfNeeded()
        }
    }

    func updatePlaybackControlSafeAreaInsets() {
        guard isViewLoaded else { return }
        let usesManualLandscape = isUsingManualLandscape && isLandscapeForced
        updatePlaybackControlLayout(isCompact: usesManualLandscape)
        let insets = Self.playbackControlHorizontalInsets(
            rootBounds: view.bounds,
            rootSafeAreaInsets: view.safeAreaInsets,
            usesManualLandscape: usesManualLandscape
        )
        closeButtonLeadingConstraint?.constant = 12 + insets.left
        statusLabelTrailingConstraint?.constant = -(12 + insets.right)
        transportStackLeadingConstraint?.constant = 12 + insets.left
        progressSliderTrailingConstraint?.constant = -(12 + insets.right)
        closeButtonTopSafeAreaConstraint?.isActive = usesManualLandscape == false
        closeButtonTopEdgeConstraint?.isActive = usesManualLandscape
        trackButtonStackBottomSafeAreaConstraint?.isActive = usesManualLandscape == false
        trackButtonStackBottomEdgeConstraint?.isActive = usesManualLandscape
    }

    private func updatePlaybackControlLayout(isCompact: Bool) {
        NSLayoutConstraint.deactivate(regularPlaybackControlLayoutConstraints)
        NSLayoutConstraint.deactivate(compactPlaybackControlLayoutConstraints)
        NSLayoutConstraint.activate(
            isCompact
                ? compactPlaybackControlLayoutConstraints
                : regularPlaybackControlLayoutConstraints
        )
    }

    static func playbackControlHorizontalInsets(
        rootBounds: CGRect,
        rootSafeAreaInsets: UIEdgeInsets,
        usesManualLandscape: Bool
    ) -> UIEdgeInsets {
        guard usesManualLandscape, rootBounds.height > rootBounds.width else {
            return UIEdgeInsets(
                top: 0,
                left: rootSafeAreaInsets.left,
                bottom: 0,
                right: rootSafeAreaInsets.right
            )
        }
        return UIEdgeInsets(
            top: 0,
            left: rootSafeAreaInsets.top,
            bottom: 0,
            right: rootSafeAreaInsets.bottom
        )
    }

    private func applyManualLandscape() {
        guard isViewLoaded else { return }
        view.setNeedsLayout()
        layoutOrientationContentView()
        updatePlaybackControlSafeAreaInsets()
        actionSheetOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
        cacheSettingsOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
    }

    private func restoreManualLandscape() {
        guard isViewLoaded else { return }
        layoutOrientationContentView()
        updatePlaybackControlSafeAreaInsets()
        actionSheetOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
        cacheSettingsOverlay?.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
    }
}
