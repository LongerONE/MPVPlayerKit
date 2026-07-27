import UIKit

extension MPVQuickPlayerViewController {
    func configureTransportControls() {
        transportStack.axis = .horizontal
        transportStack.alignment = .center
        transportStack.spacing = 4
        controlsView.addSubview(transportStack)

        configureTransportButton(
            backwardButton,
            symbol: .skipBackward15,
            label: mpvLocalized("accessibility.skip_backward_15_seconds"),
            identifier: "MPVQuickPlayer.backward15Button",
            action: #selector(skipBackward15Seconds)
        )
        configureTransportButton(
            playButton,
            symbol: .play,
            label: mpvLocalized("accessibility.play_pause"),
            identifier: "MPVQuickPlayer.playButton",
            action: #selector(togglePlayback)
        )
        configureTransportButton(
            forwardButton,
            symbol: .skipForward15,
            label: mpvLocalized("accessibility.skip_forward_15_seconds"),
            identifier: "MPVQuickPlayer.forward15Button",
            action: #selector(skipForward15Seconds)
        )
    }

    func configureTransportButton(
        _ button: UIButton,
        symbol: MPVQuickPlayerSymbol,
        label: String,
        identifier: String,
        action: Selector
    ) {
        button.tintColor = .white
        button.setImage(MPVQuickPlayerSymbol.image(symbol, pointSize: 20), for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
        transportStack.addArrangedSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    func configureControlButton(
        _ button: UIButton,
        symbol: MPVQuickPlayerSymbol,
        label: String,
        action: Selector
    ) {
        button.setImage(MPVQuickPlayerSymbol.image(symbol, pointSize: 17), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = label
        trackButtonStack.addArrangedSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc func togglePlayback() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    @objc func skipBackward15Seconds() {
        seek(by: -MPVSystemPlaybackControls.skipInterval)
    }

    @objc func skipForward15Seconds() {
        seek(by: MPVSystemPlaybackControls.skipInterval)
    }

    func seek(by offset: TimeInterval) {
        let target = MPVSystemPlaybackControls.seekTarget(
            currentTime: player.currentTime,
            duration: player.duration,
            offset: offset
        )
        _ = player.seek(to: target, autoPlay: player.isPlaying)
    }
}
