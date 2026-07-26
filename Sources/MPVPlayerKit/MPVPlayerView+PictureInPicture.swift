import AVKit
import UIKit

/// Hosts the player view inside the system Picture in Picture window.
///
/// The video-call content source is the only public API that can host a
/// `UIView`, and hosting is what keeps the window on MPV's own renderer: the
/// same `gpu-next` and libplacebo pipeline that handles Dolby Vision and HDR
/// tone mapping inline draws the window, at the video's own frame rate. The
/// sample buffer content source cannot do that, because it can only be fed
/// frames read back from MPV, which costs a full frame readback each time and
/// loses the renderer's colorimetry.
///
/// The trade is that this content source has no system transport controls, so
/// the window shows the video alone.
@MainActor
private final class MPVPictureInPictureContentViewController:
    AVPictureInPictureVideoCallViewController
{
    weak var coordinator: MPVPictureInPictureCoordinator?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        coordinator?.movePlayerToPictureInPictureContainer(view)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        coordinator?.restorePlayerToInlineHierarchy()
    }
}

@MainActor
final class MPVPictureInPictureCoordinator:
    NSObject,
    @preconcurrency AVPictureInPictureControllerDelegate
{
    weak var playerView: MPVPlayerView?
    private var placement: MPVPictureInPictureViewPlacement?
    private var contentViewController: MPVPictureInPictureContentViewController?
    private var controller: AVPictureInPictureController?
    private var isStarting = false
    private var isStartCancellationRequested = false
    private var isTearingDown = false
    private var hasPostedActiveState = false

    var allowsAutomaticStartFromInline: Bool {
        didSet {
            prepareControllerIfPossible()
            controller?.canStartPictureInPictureAutomaticallyFromInline =
                allowsAutomaticStartFromInline
            if allowsAutomaticStartFromInline == false, isActive == false {
                tearDownController()
            }
        }
    }

    var isActive: Bool {
        controller?.isPictureInPictureActive == true
    }

    init?(playerView: MPVPlayerView, allowsAutomaticStartFromInline: Bool) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        self.playerView = playerView
        self.allowsAutomaticStartFromInline = allowsAutomaticStartFromInline
        super.init()
        prepareControllerIfPossible()
    }

    deinit {
        MainActor.assumeIsolated { placement?.tearDown() }
    }

    func start() {
        // A coordinator survives a normal player stop, so an explicit start is
        // a new lifecycle rather than a continuation of the torn down one.
        isTearingDown = false
        guard isActive == false, isStarting == false else { return }
        prepareControllerIfPossible()
        guard let controller else { return }
        playerView?.mpvDebugLog(
            "pip start requested possible=\(controller.isPictureInPicturePossible)"
        )
        isStartCancellationRequested = false
        isStarting = true
        controller.startPictureInPicture()
    }

    func stop() {
        guard let controller else {
            restorePlayerToInlineHierarchy()
            return
        }
        if controller.isPictureInPictureActive == false, isStarting {
            isStartCancellationRequested = true
            controller.stopPictureInPicture()
            restorePlayerToInlineHierarchy()
            return
        }
        isStarting = false
        guard controller.isPictureInPictureActive else {
            restorePlayerToInlineHierarchy()
            return
        }
        controller.stopPictureInPicture()
    }

    /// The player view must be back in its inline hierarchy before MPV is torn
    /// down: the Metal layer it renders into travels with the view, and the
    /// window would otherwise outlive the renderer feeding it.
    func stopForPlayerTeardown() {
        isTearingDown = true
        isStartCancellationRequested = true
        guard isActive || isStarting else {
            restorePlayerToInlineHierarchy()
            return
        }
        isStarting = false
        controller?.stopPictureInPicture()
        restorePlayerToInlineHierarchy()
    }

    func playerViewHierarchyDidChange() {
        prepareControllerIfPossible()
    }

    /// Shapes the window like the video rather than like the inline view, which
    /// is usually a portrait container the video is letterboxed into.
    func playerVideoDisplaySizeDidChange() {
        guard let playerView else { return }
        contentViewController?.preferredContentSize =
            playerView.pictureInPicturePreferredContentSize
    }

    func movePlayerToPictureInPictureContainer(_ containerView: UIView) {
        guard MPVPictureInPictureStartCancellationPolicy.shouldMovePlayer(
            isStarting: isStarting,
            isActive: isActive,
            isCancellationRequested: isStartCancellationRequested || isTearingDown
        ) else {
            return
        }
        placement?.movePlayer(to: containerView)
    }

    func restorePlayerToInlineHierarchy() {
        placement?.restorePlayer()
    }

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
            isStartCancellationRequested: isStartCancellationRequested,
            isTearingDown: isTearingDown
        ) else {
            isStarting = false
            pictureInPictureController.stopPictureInPicture()
            restorePlayerToInlineHierarchy()
            return
        }
        isStarting = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard MPVPictureInPictureTeardownPolicy.shouldStartSystemController(
            isStartCancellationRequested: isStartCancellationRequested,
            isTearingDown: isTearingDown
        ) else {
            isStarting = false
            pictureInPictureController.stopPictureInPicture()
            restorePlayerToInlineHierarchy()
            return
        }
        isStarting = false
        hasPostedActiveState = true
        postStateChange(isActive: true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        playerView?.mpvDebugLog("pip start failed error=\(error.localizedDescription)")
        finishStop()
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        restorePlayerToInlineHierarchy()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        finishStop()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        restorePlayerToInlineHierarchy()
        completionHandler(true)
    }

    private func finishStop() {
        let shouldPostInactiveState = MPVPictureInPictureStartCancellationPolicy
            .shouldPostInactiveState(
                hasPostedActiveState: hasPostedActiveState,
                isStartCancellationRequested: isStartCancellationRequested
            )
        isStarting = false
        isStartCancellationRequested = false
        restorePlayerToInlineHierarchy()
        guard shouldPostInactiveState else { return }
        hasPostedActiveState = false
        postStateChange(isActive: false)
    }

    private func prepareControllerIfPossible() {
        guard controller == nil,
              let playerView,
              playerView.superview != nil,
              playerView.window != nil,
              let placement = MPVPictureInPictureViewPlacement(playerView: playerView)
        else {
            return
        }

        let contentViewController = MPVPictureInPictureContentViewController()
        contentViewController.coordinator = self
        contentViewController.preferredContentSize =
            playerView.pictureInPicturePreferredContentSize
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: placement.sourceView,
            contentViewController: contentViewController
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline =
            allowsAutomaticStartFromInline
        self.placement = placement
        self.contentViewController = contentViewController
        self.controller = controller
    }

    private func tearDownController() {
        guard isActive == false, isStarting == false else { return }
        controller?.delegate = nil
        controller = nil
        contentViewController = nil
        placement?.tearDown()
        placement = nil
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
