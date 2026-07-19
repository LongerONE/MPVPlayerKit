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
    }

    private func applyManualLandscape() {
        guard isViewLoaded else { return }
        view.setNeedsLayout()
        layoutOrientationContentView()
    }

    private func restoreManualLandscape() {
        guard isViewLoaded else { return }
        layoutOrientationContentView()
    }
}
