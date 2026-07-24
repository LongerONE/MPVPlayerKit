import AVKit
import UIKit

enum MPVPictureInPictureStartCancellationPolicy {
    static func shouldMovePlayer(
        isStarting: Bool,
        isActive: Bool,
        isCancellationRequested: Bool
    ) -> Bool {
        isCancellationRequested == false && (isStarting || isActive)
    }

    static func shouldPostInactiveState(
        hasPostedActiveState: Bool,
        isStartCancellationRequested: Bool
    ) -> Bool {
        hasPostedActiveState && isStartCancellationRequested == false
    }
}

enum MPVPictureInPictureContentSize {
    static let fallback = CGSize(width: 16, height: 9)

    static func resolve(videoDisplaySize: CGSize) -> CGSize {
        guard videoDisplaySize.width > 0, videoDisplaySize.height > 0,
              videoDisplaySize.width.isFinite, videoDisplaySize.height.isFinite
        else {
            return fallback
        }
        return videoDisplaySize
    }
}

/// Keeps the inline anchor visible while the player view is hosted by the
/// system Picture in Picture controller. The video-call ContentSource API is
/// available on iOS 15 and is the only public API that can host a UIView.
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
final class MPVPictureInPictureViewPlacement {
    private weak var playerView: MPVPlayerView?
    private weak var originalSuperview: UIView?
    private let originalSubviewIndex: Int
    private let originalFrame: CGRect
    private let originalAutoresizingMask: UIView.AutoresizingMask
    private let originalTranslatesAutoresizingMaskIntoConstraints: Bool
    let sourceView = UIView()
    private var originalConstraints: [NSLayoutConstraint] = []
    private var sourceConstraints: [NSLayoutConstraint] = []
    private var pictureInPictureConstraints: [NSLayoutConstraint] = []
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
        originalFrame = playerView.frame
        originalAutoresizingMask = playerView.autoresizingMask
        originalTranslatesAutoresizingMaskIntoConstraints =
            playerView.translatesAutoresizingMaskIntoConstraints

        sourceView.backgroundColor = .clear
        sourceView.isUserInteractionEnabled = false
        sourceView.accessibilityElementsHidden = true
        installSourceView(below: playerView, in: superview, at: index)
    }

    func movePlayer(to containerView: UIView) {
        guard isPlayerInPictureInPictureContainer == false,
              let playerView
        else {
            return
        }

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
        isPlayerInPictureInPictureContainer = true
    }

    func restorePlayer() {
        guard isPlayerInPictureInPictureContainer,
              let playerView,
              let originalSuperview
        else {
            return
        }

        pictureInPictureConstraints.forEach { $0.isActive = false }
        pictureInPictureConstraints.removeAll()
        playerView.removeFromSuperview()
        let insertionIndex = min(originalSubviewIndex, originalSuperview.subviews.count)
        originalSuperview.insertSubview(playerView, at: insertionIndex)
        playerView.translatesAutoresizingMaskIntoConstraints =
            originalTranslatesAutoresizingMaskIntoConstraints
        playerView.autoresizingMask = originalAutoresizingMask
        playerView.frame = originalFrame
        originalConstraints.forEach { $0.isActive = true }
        isPlayerInPictureInPictureContainer = false
    }

    func tearDown() {
        restorePlayer()
        sourceConstraints.forEach { $0.isActive = false }
        sourceConstraints.removeAll()
        sourceView.removeFromSuperview()
    }

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
        guard #available(iOS 15.0, *),
              AVPictureInPictureController.isPictureInPictureSupported()
        else {
            return nil
        }
        self.playerView = playerView
        self.allowsAutomaticStartFromInline = allowsAutomaticStartFromInline
        super.init()
        prepareControllerIfPossible()
    }

    deinit {
        MainActor.assumeIsolated { placement?.tearDown() }
    }

    func start() {
        guard isActive == false, isStarting == false else { return }
        prepareControllerIfPossible()
        guard let controller else { return }
        updatePreferredContentSize()
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

    func playerViewHierarchyDidChange() {
        prepareControllerIfPossible()
    }

    func playerVideoDisplaySizeDidChange() {
        updatePreferredContentSize()
    }

    func movePlayerToPictureInPictureContainer(_ containerView: UIView) {
        guard MPVPictureInPictureStartCancellationPolicy.shouldMovePlayer(
            isStarting: isStarting,
            isActive: isActive,
            isCancellationRequested: isStartCancellationRequested
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
        if isStartCancellationRequested {
            pictureInPictureController.stopPictureInPicture()
            restorePlayerToInlineHierarchy()
            return
        }
        isStarting = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        if isStartCancellationRequested {
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
        let shouldPostInactiveState = hasPostedActiveState
        let wasStartCancellationRequested = isStartCancellationRequested
        isStarting = false
        isStartCancellationRequested = false
        restorePlayerToInlineHierarchy()
        if MPVPictureInPictureStartCancellationPolicy.shouldPostInactiveState(
            hasPostedActiveState: shouldPostInactiveState,
            isStartCancellationRequested: wasStartCancellationRequested
        ) {
            hasPostedActiveState = false
            postStateChange(isActive: false)
        }
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        restorePlayerToInlineHierarchy()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        let wasStartCancellationRequested = isStartCancellationRequested
        isStarting = false
        isStartCancellationRequested = false
        restorePlayerToInlineHierarchy()
        if MPVPictureInPictureStartCancellationPolicy.shouldPostInactiveState(
            hasPostedActiveState: hasPostedActiveState,
            isStartCancellationRequested: wasStartCancellationRequested
        ) {
            hasPostedActiveState = false
            postStateChange(isActive: false)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        restorePlayerToInlineHierarchy()
        completionHandler(true)
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
        contentViewController.preferredContentSize = playerView.pictureInPicturePreferredContentSize
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

    private func updatePreferredContentSize() {
        guard let playerView else { return }
        contentViewController?.preferredContentSize = playerView.pictureInPicturePreferredContentSize
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

public extension MPVPlayerView {
    @objc var isPictureInPictureSupported: Bool {
        pictureInPictureCoordinatorInstance != nil
    }

    @objc var isPictureInPictureActive: Bool {
        pictureInPictureCoordinator?.isActive == true
    }

    @objc var allowsAutomaticPictureInPictureFromInline: Bool {
        get { pictureInPictureCoordinator?.allowsAutomaticStartFromInline ?? false }
        set { pictureInPictureCoordinatorInstance?.allowsAutomaticStartFromInline = newValue }
    }

    @objc func startPictureInPicture() {
        pictureInPictureCoordinatorInstance?.start()
    }

    @objc func stopPictureInPicture() {
        pictureInPictureCoordinator?.stop()
    }

    @objc func togglePictureInPicture() {
        isPictureInPictureActive ? stopPictureInPicture() : startPictureInPicture()
    }
}

extension MPVPlayerView {
    var pictureInPicturePreferredContentSize: CGSize {
        MPVPictureInPictureContentSize.resolve(
            videoDisplaySize: pictureInPictureVideoDisplaySize
        )
    }

    func updatePictureInPictureVideoDisplaySize(_ size: CGSize) {
        let resolvedSize = MPVPictureInPictureContentSize.resolve(videoDisplaySize: size)
        guard pictureInPictureVideoDisplaySize != resolvedSize else { return }
        pictureInPictureVideoDisplaySize = resolvedSize
        pictureInPictureCoordinator?.playerVideoDisplaySizeDidChange()
    }

    func pictureInPictureViewHierarchyDidChange() {
        pictureInPictureCoordinator?.playerViewHierarchyDidChange()
    }

    private var pictureInPictureCoordinatorInstance: MPVPictureInPictureCoordinator? {
        if let pictureInPictureCoordinator { return pictureInPictureCoordinator }
        let coordinator = MPVPictureInPictureCoordinator(
            playerView: self,
            allowsAutomaticStartFromInline: false
        )
        pictureInPictureCoordinator = coordinator
        return coordinator
    }
}
