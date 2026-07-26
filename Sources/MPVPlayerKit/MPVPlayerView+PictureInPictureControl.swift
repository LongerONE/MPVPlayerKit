import AVKit
import CoreGraphics
import UIKit

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
        MPVSystemPlaybackCoordinator.shared.activate(playerView: self)
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
        MPVPictureInPictureContentSize.resolve(videoDisplaySize: pictureInPictureVideoDisplaySize)
    }

    func resetPictureInPictureVideoOutputReadiness() {
        hasPictureInPictureVideoOutputParameters = false
        hasPictureInPictureFirstVideoFrameSignal = false
    }

    func updatePictureInPictureVideoDisplaySize(
        _ size: CGSize,
        signal: MPVPictureInPictureVideoOutputSignal = .none
    ) {
        let hasValidParameters = size.width > 0 && size.height > 0
        hasPictureInPictureVideoOutputParameters = hasValidParameters
        if hasValidParameters == false {
            hasPictureInPictureFirstVideoFrameSignal = false
        } else if signal.establishesFirstVideoFrameReadiness {
            hasPictureInPictureFirstVideoFrameSignal = true
        }
        let resolvedSize = MPVPictureInPictureContentSize.resolve(videoDisplaySize: size)
        guard pictureInPictureVideoDisplaySize != resolvedSize else { return }
        pictureInPictureVideoDisplaySize = resolvedSize
        pictureInPictureCoordinator?.playerVideoDisplaySizeDidChange()
    }

    func pictureInPictureViewHierarchyDidChange() {
        pictureInPictureCoordinator?.playerViewHierarchyDidChange()
    }

    func pictureInPictureViewDidLayout() {
        pictureInPictureCoordinator?.playerViewDidLayout()
    }

    func pictureInPicturePlaybackStateDidChange() {
        pictureInPictureCoordinator?.playbackStateDidChange()
    }

    func stopPictureInPictureForPlayerTeardown() {
        pictureInPictureCoordinator?.stopForPlayerTeardown()
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

enum MPVPictureInPictureVideoOutputSignal: Sendable {
    case none
    case fileLoaded
    case playbackRestart
    case videoReconfiguration

    var establishesFirstVideoFrameReadiness: Bool {
        switch self {
        case .playbackRestart, .videoReconfiguration:
            true
        case .none, .fileLoaded:
            false
        }
    }
}
