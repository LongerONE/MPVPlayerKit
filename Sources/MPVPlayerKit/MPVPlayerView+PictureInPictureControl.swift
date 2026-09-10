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

    /// 进入画中画时，仅当宿主允许库内系统播放控制才激活 Now Playing。
    /// 宿主自行管理远程命令时（`systemPlaybackControlsEnabled == false`），
    /// 库不在 PiP 时抢占 owner；画中画窗口本身仍可用。
    @objc func startPictureInPicture() {
        if systemPlaybackControlsEnabled {
            activateSystemPlaybackControlsForPictureInPicture()
        }
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
    func activateSystemPlaybackControlsForPictureInPicture() {
        let sessionGeneration = currentBufferingSessionGeneration()
        let intentGeneration = currentPlaybackIntentGeneration()
        queue.async { [weak self] in
            guard let self,
                  self.currentBufferingSessionGeneration() == sessionGeneration,
                  self.currentPlaybackIntentGeneration() == intentGeneration,
                  self.isStopped() == false
            else { return }
            let isTimeAdvancing = self.mpv != nil
                && self.bufferingStateMachine.state == .finished
            self.notifyOnMain {
                guard self.currentBufferingSessionGeneration() == sessionGeneration,
                      self.currentPlaybackIntentGeneration() == intentGeneration,
                      self.isStopped() == false
                else { return }
                MPVSystemPlaybackCoordinator.shared.activate(
                    playerView: self,
                    isTimeAdvancing: isTimeAdvancing
                )
            }
        }
    }

    /// The window is shaped like the video, not like the inline view, which is
    /// usually a portrait container the video is letterboxed into.
    var pictureInPicturePreferredContentSize: CGSize {
        MPVPictureInPictureContentSize.resolve(videoDisplaySize: pictureInPictureVideoDisplaySize)
    }

    func resetPictureInPictureVideoDisplaySize() {
        updatePictureInPictureVideoDisplaySize(.zero)
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
