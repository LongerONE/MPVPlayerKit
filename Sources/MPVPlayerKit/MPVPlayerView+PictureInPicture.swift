import AVKit
import QuartzCore
import UIKit

@MainActor
final class MPVPictureInPictureContentViewController:
    AVPictureInPictureVideoCallViewController
{
    weak var playerView: MPVPlayerView?

    init(playerView: MPVPlayerView) {
        self.playerView = playerView
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = playerView.pictureInPicturePreferredContentSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.layer.masksToBounds = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        layoutPlayerLayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPlayerLayer()
    }

    func layoutPlayerLayer() {
        guard view.bounds.width > 1, view.bounds.height > 1 else { return }
        playerView?.displayMetalLayerForPictureInPicture(
            in: view.layer,
            bounds: view.bounds,
            scale: view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        )
    }
}

@MainActor
final class MPVPictureInPictureCoordinator:
    NSObject,
    @preconcurrency AVPictureInPictureControllerDelegate
{
    weak var playerView: MPVPlayerView?
    private let contentViewController: MPVPictureInPictureContentViewController
    private let controller: AVPictureInPictureController

    var allowsAutomaticStartFromInline: Bool {
        didSet {
            controller.canStartPictureInPictureAutomaticallyFromInline = allowsAutomaticStartFromInline
        }
    }

    var isActive: Bool {
        controller.isPictureInPictureActive
    }

    init?(playerView: MPVPlayerView, allowsAutomaticStartFromInline: Bool) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }

        self.playerView = playerView
        self.allowsAutomaticStartFromInline = allowsAutomaticStartFromInline
        contentViewController = MPVPictureInPictureContentViewController(playerView: playerView)
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: playerView,
            contentViewController: contentViewController
        )
        controller = AVPictureInPictureController(contentSource: source)
        super.init()
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = allowsAutomaticStartFromInline
    }

    func start() {
        guard controller.isPictureInPictureActive == false else { return }
        controller.startPictureInPicture()
    }

    func stop() {
        guard controller.isPictureInPictureActive else {
            playerView?.restoreMetalLayerAfterPictureInPicture()
            return
        }
        controller.stopPictureInPicture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        postStateChange(isActive: true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        playerView?.restoreMetalLayerAfterPictureInPicture()
        postStateChange(isActive: false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        playerView?.restoreMetalLayerAfterPictureInPicture()
        postStateChange(isActive: false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    private func postStateChange(isActive: Bool) {
        guard let playerView else { return }
        NotificationCenter.default.post(
            name: MPVPlayerKitNotification.didChangePictureInPicture,
            object: playerView,
            userInfo: ["isActive": isActive]
        )
    }
}

public extension MPVPlayerView {
    /// Whether Picture in Picture is available on the current device.
    @objc var isPictureInPictureSupported: Bool {
        pictureInPictureCoordinatorInstance != nil
    }

    /// Whether the player is currently presented in Picture in Picture.
    @objc var isPictureInPictureActive: Bool {
        pictureInPictureCoordinator?.isActive == true
    }

    /// Lets the system automatically enter Picture in Picture when the app moves
    /// to the background while this player is visible.
    @objc var allowsAutomaticPictureInPictureFromInline: Bool {
        get {
            pictureInPictureCoordinator?.allowsAutomaticStartFromInline ?? false
        }
        set {
            pictureInPictureCoordinatorInstance?.allowsAutomaticStartFromInline = newValue
        }
    }

    /// Starts Picture in Picture. Call this directly from a user interaction.
    @objc func startPictureInPicture() {
        pictureInPictureCoordinatorInstance?.start()
    }

    /// Stops Picture in Picture and restores rendering to the inline player.
    @objc func stopPictureInPicture() {
        pictureInPictureCoordinator?.stop()
    }

    /// Starts or stops Picture in Picture according to the current state.
    @objc func togglePictureInPicture() {
        if isPictureInPictureActive {
            stopPictureInPicture()
        } else {
            startPictureInPicture()
        }
    }
}

extension MPVPlayerView {
    var pictureInPicturePreferredContentSize: CGSize {
        CGSize(width: 16, height: 9)
    }

    private var pictureInPictureCoordinatorInstance: MPVPictureInPictureCoordinator? {
        if let pictureInPictureCoordinator {
            return pictureInPictureCoordinator
        }
        let coordinator = MPVPictureInPictureCoordinator(
            playerView: self,
            allowsAutomaticStartFromInline: false
        )
        pictureInPictureCoordinator = coordinator
        return coordinator
    }

    func displayMetalLayerForPictureInPicture(
        in containerLayer: CALayer,
        bounds: CGRect,
        scale: CGFloat
    ) {
        isRenderingInPictureInPicture = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if metalLayer.superlayer !== containerLayer {
            metalLayer.removeFromSuperlayer()
            containerLayer.addSublayer(metalLayer)
        }
        CATransaction.commit()
        updateMetalLayerGeometry(
            for: bounds,
            scale: scale,
            transitionReason: "picture-in-picture",
            animated: false
        )
    }

    func restoreMetalLayerAfterPictureInPicture() {
        guard isRenderingInPictureInPicture || metalLayer.superlayer !== layer else { return }
        isRenderingInPictureInPicture = false
        metalLayer.removeFromSuperlayer()
        layer.addSublayer(metalLayer)
        updateMetalLayerGeometry(
            for: CGRect(origin: .zero, size: bounds.size),
            scale: UIScreen.main.nativeScale,
            transitionReason: "picture-in-picture-restore",
            animated: false
        )
    }
}
