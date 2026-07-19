import UIKit

extension MPVQuickPlayerViewController {
    /// Locks the quick player to landscape-right or restores automatic rotation.
    public func setForceLandscape(_ forced: Bool) {
        guard isLandscapeForced != forced else {
            applyPreferredOrientationIfNeeded()
            return
        }

        isLandscapeForced = forced
        updateOrientationButton()
        invalidateSupportedInterfaceOrientations()
        requestInterfaceOrientation(forced ? .landscapeRight : .portrait)
    }

    @objc func toggleForcedLandscape() {
        setForceLandscape(isLandscapeForced == false)
    }

    func applyPreferredOrientationIfNeeded() {
        updateOrientationButton()
        guard isLandscapeForced else { return }
        invalidateSupportedInterfaceOrientations()
        requestInterfaceOrientation(.landscapeRight)
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
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
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
}
