import UIKit

extension MPVQuickPlayerViewController {
    func configureLayout() {
        let constrainedViews = [
            player.playbackView,
            topBar,
            closeButton,
            orientationButton,
            statusLabel,
            loadingIndicator,
            controlsView,
            transportStack,
            progressSlider,
            timeLabel,
            trackButtonStack,
            systemVolumeView,
            gestureHUD,
            gestureHUDIcon,
            gestureHUDLabel,
            gestureHUDProgress,
        ]
        constrainedViews.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        let topSafeArea = topBar.safeAreaLayoutGuide
        let controlsSafeArea = controlsView.safeAreaLayoutGuide
        let hudContentView = gestureHUD.contentView
        closeButtonLeadingConstraint = closeButton.leadingAnchor.constraint(
            equalTo: topBar.leadingAnchor,
            constant: 12
        )
        statusLabelTrailingConstraint = statusLabel.trailingAnchor.constraint(
            equalTo: topBar.trailingAnchor,
            constant: -12
        )
        transportStackLeadingConstraint = transportStack.leadingAnchor.constraint(
            equalTo: controlsView.leadingAnchor,
            constant: 12
        )
        progressSliderTrailingConstraint = progressSlider.trailingAnchor.constraint(
            equalTo: controlsView.trailingAnchor,
            constant: -12
        )
        closeButtonTopSafeAreaConstraint = closeButton.topAnchor.constraint(
            equalTo: topSafeArea.topAnchor,
            constant: 8
        )
        closeButtonTopEdgeConstraint = closeButton.topAnchor.constraint(
            equalTo: topBar.topAnchor,
            constant: 8
        )
        trackButtonStackBottomSafeAreaConstraint = trackButtonStack.bottomAnchor.constraint(
            equalTo: controlsSafeArea.bottomAnchor,
            constant: -10
        )
        trackButtonStackBottomEdgeConstraint = trackButtonStack.bottomAnchor.constraint(
            equalTo: controlsView.bottomAnchor,
            constant: -10
        )
        closeButtonTopSafeAreaConstraint.isActive = isUsingManualLandscape == false
        closeButtonTopEdgeConstraint.isActive = isUsingManualLandscape
        trackButtonStackBottomSafeAreaConstraint.isActive = isUsingManualLandscape == false
        trackButtonStackBottomEdgeConstraint.isActive = isUsingManualLandscape
        regularPlaybackControlLayoutConstraints = [
            timeLabel.trailingAnchor.constraint(equalTo: progressSlider.trailingAnchor),
            trackButtonStack.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 6),
            trackButtonStack.centerXAnchor.constraint(equalTo: controlsView.centerXAnchor),
            trackButtonStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: timeLabel.leadingAnchor
            ),
            trackButtonStack.trailingAnchor.constraint(
                lessThanOrEqualTo: timeLabel.trailingAnchor
            ),
        ]
        compactPlaybackControlLayoutConstraints = [
            timeLabel.trailingAnchor.constraint(equalTo: trackButtonStack.leadingAnchor, constant: -8),
            trackButtonStack.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            trackButtonStack.trailingAnchor.constraint(equalTo: progressSlider.trailingAnchor),
        ]
        duoMediaConstraints = [
            player.playbackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            player.playbackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            player.playbackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            player.playbackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ]
        duoTopBarConstraints = [
            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor)
        ]
        duoControlsConstraints = [
            controlsView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ]
        NSLayoutConstraint.activate(duoMediaConstraints + duoTopBarConstraints + duoControlsConstraints)
        NSLayoutConstraint.activate([
            closeButtonLeadingConstraint,
            closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            orientationButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            orientationButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            orientationButton.widthAnchor.constraint(equalToConstant: 36),
            orientationButton.heightAnchor.constraint(equalToConstant: 36),

            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: orientationButton.trailingAnchor, constant: 12),
            statusLabelTrailingConstraint,
            statusLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: player.playbackView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: player.playbackView.centerYAnchor),

            transportStackLeadingConstraint,
            transportStack.topAnchor.constraint(equalTo: controlsView.topAnchor, constant: 10),

            progressSlider.leadingAnchor.constraint(equalTo: transportStack.trailingAnchor, constant: 8),
            progressSliderTrailingConstraint,
            progressSlider.centerYAnchor.constraint(equalTo: transportStack.centerYAnchor),

            timeLabel.leadingAnchor.constraint(equalTo: transportStack.leadingAnchor),
            timeLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 6),

            systemVolumeView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            systemVolumeView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            systemVolumeView.widthAnchor.constraint(equalToConstant: 1),
            systemVolumeView.heightAnchor.constraint(equalToConstant: 1),

            gestureHUD.centerXAnchor.constraint(equalTo: player.playbackView.centerXAnchor),
            gestureHUD.centerYAnchor.constraint(equalTo: player.playbackView.centerYAnchor),
            gestureHUD.widthAnchor.constraint(equalToConstant: 220),

            gestureHUDIcon.topAnchor.constraint(equalTo: hudContentView.topAnchor, constant: 14),
            gestureHUDIcon.centerXAnchor.constraint(equalTo: hudContentView.centerXAnchor),
            gestureHUDIcon.widthAnchor.constraint(equalToConstant: 24),
            gestureHUDIcon.heightAnchor.constraint(equalToConstant: 24),

            gestureHUDLabel.topAnchor.constraint(equalTo: gestureHUDIcon.bottomAnchor, constant: 8),
            gestureHUDLabel.leadingAnchor.constraint(equalTo: hudContentView.leadingAnchor, constant: 12),
            gestureHUDLabel.trailingAnchor.constraint(equalTo: hudContentView.trailingAnchor, constant: -12),

            gestureHUDProgress.topAnchor.constraint(equalTo: gestureHUDLabel.bottomAnchor, constant: 10),
            gestureHUDProgress.leadingAnchor.constraint(equalTo: hudContentView.leadingAnchor, constant: 16),
            gestureHUDProgress.trailingAnchor.constraint(equalTo: hudContentView.trailingAnchor, constant: -16),
            gestureHUDProgress.bottomAnchor.constraint(equalTo: hudContentView.bottomAnchor, constant: -14),
        ])
        NSLayoutConstraint.activate(
            isUsingManualLandscape
                ? compactPlaybackControlLayoutConstraints
                : regularPlaybackControlLayoutConstraints
        )
    }

}
