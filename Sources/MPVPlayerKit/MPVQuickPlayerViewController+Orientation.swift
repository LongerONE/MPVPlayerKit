import UIKit

extension MPVQuickPlayerViewController {
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
            applyManualLandscape(animated: true)
        } else {
            restoreManualLandscape(animated: true)
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
            applyManualLandscape(animated: false)
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
                guard orientation != .portrait, let self else { return }
                isUsingManualLandscape = true
                invalidateSupportedInterfaceOrientations()
                applyManualLandscape(animated: true)
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
        contentView.transform = .identity

        guard isUsingManualLandscape, isLandscapeForced, rootBounds.height > rootBounds.width else {
            contentView.frame = rootBounds
            return
        }

        contentView.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: rootBounds.height, height: rootBounds.width)
        )
        contentView.center = CGPoint(x: rootBounds.midX, y: rootBounds.midY)
        contentView.transform = CGAffineTransform(rotationAngle: .pi / 2)
    }

    private func applyManualLandscape(animated: Bool) {
        view.setNeedsLayout()
        let updates = { [weak self] in
            self?.layoutOrientationContentView()
            self?.contentView.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.3, animations: updates)
        } else {
            updates()
        }
    }

    private func restoreManualLandscape(animated: Bool) {
        guard isViewLoaded else { return }
        let updates = { [weak self] in
            guard let self else { return }
            contentView.transform = .identity
            contentView.frame = view.bounds
            contentView.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.3, animations: updates)
        } else {
            updates()
        }
    }
}
