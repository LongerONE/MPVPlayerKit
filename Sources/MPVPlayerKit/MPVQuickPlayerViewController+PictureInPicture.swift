import AVFoundation

extension MPVQuickPlayerViewController {

    @objc func startPictureInPicture() {
        guard player.isPictureInPictureActive == false else {
            player.stopPictureInPicture()
            return
        }

        Task { @MainActor [weak self] in
            guard let self,
                  await preparePictureInPicturePlayback() else { return }
            guard player.isPictureInPictureActive == false else { return }
            player.startPictureInPicture()
        }
    }

    func updatePictureInPictureButton(isActive: Bool) {
        pictureInPictureButton.setImage(
            MPVQuickPlayerSymbol.image(
                isActive ? .pictureInPictureExit : .pictureInPictureEnter,
                pointSize: 17
            ),
            for: .normal
        )
    }

    @discardableResult
    func preparePictureInPicturePlayback(
        activateAudioSession: @MainActor () async throws -> Void = MPVQuickPlayerViewController
            .activateMoviePlaybackAudioSession
    ) async -> Bool {
        guard player.isPictureInPictureSupported else { return false }
        do {
            try await activateAudioSession()
            // The player view keeps automatic PiP disabled by default. Do not
            // set it again here: changing this property tears down an inactive
            // controller that may already have been prepared by the view's
            // window lifecycle, so the explicit start can become a no-op.
            return true
        } catch {
            return false
        }
    }

    static func activateMoviePlaybackAudioSession() async throws {
        try await Task.detached(priority: .userInitiated) {
            let audioSession = AVAudioSession.sharedInstance()
            if audioSession.category != .playback || audioSession.mode != .moviePlayback {
                try audioSession.setCategory(.playback, mode: .moviePlayback)
            }
            try audioSession.setActive(true)
        }.value
    }
}
