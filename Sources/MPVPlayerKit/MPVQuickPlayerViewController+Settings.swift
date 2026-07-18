import MediaPlayer
import UIKit
import UniformTypeIdentifiers

extension MPVQuickPlayerViewController {
    @objc func showSettings() {
        let alert = actionSheet(title: mpvLocalized("settings.title"), sourceView: settingsButton)
        alert.addAction(UIAlertAction(title: mpvLocalized("settings.playback_speed.value", Self.rateTitle(playbackRate)), style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showPlaybackRatePicker() }
        })
        alert.addAction(UIAlertAction(title: mpvLocalized("settings.video_quality.value", Self.videoQualityTitle(videoQuality)), style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showVideoQualityPicker() }
        })
        alert.addAction(UIAlertAction(title: mpvLocalized("settings.frame_interpolation.value", Self.interpolationTitle(interpolationOptions.quality)), style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showInterpolationPicker() }
        })
        let debandTitle = mpvLocalized(
            debandEnabled ? "settings.disable_debanding" : "settings.enable_debanding"
        )
        alert.addAction(UIAlertAction(title: debandTitle, style: .default) { [weak self] _ in
            guard let self else { return }
            setDebandEnabled(debandEnabled == false)
        })
        let contentModeTitle = mpvLocalized(
            player.contentMode == .scaleAspectFill ? "settings.fit_video" : "settings.fill_screen"
        )
        alert.addAction(UIAlertAction(title: contentModeTitle, style: .default) { [weak self] _ in
            guard let self else { return }
            player.contentMode = player.contentMode == .scaleAspectFill ? .scaleAspectFit : .scaleAspectFill
        })
        alert.addAction(UIAlertAction(title: mpvLocalized("subtitle.delay.value", Self.delayTitle(subtitleDelay)), style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showSubtitleDelayPicker() }
        })
        alert.addAction(UIAlertAction(title: mpvLocalized("subtitle.style"), style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showSubtitleStylePicker() }
        })
        alert.addAction(UIAlertAction(title: mpvLocalized("common.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    public func setPlaybackRate(_ rate: Double) {
        let normalizedRate = min(max(rate, 0.25), 4.0)
        playbackRate = normalizedRate
        player.setPlaybackRate(normalizedRate)
        updateStatusLabel()
    }

    public func setVideoQuality(_ quality: MPVVideoQuality) {
        videoQuality = quality
        player.updateVideoQuality(quality)
    }

    public func setDebandEnabled(_ enabled: Bool) {
        debandEnabled = enabled
        player.updateVideoRenderOptions(
            debandEnabled: enabled,
            interpolationOptions: interpolationOptions
        )
    }

    public func setInterpolationOptions(_ options: MPVInterpolationOptions) {
        interpolationOptions = options
        player.updateVideoRenderOptions(
            debandEnabled: debandEnabled,
            interpolationOptions: options
        )
    }

    public func setSubtitleDelay(_ delay: TimeInterval) {
        guard delay.isFinite else { return }
        subtitleDelay = min(max(delay, -60), 60)
        player.setSubtitleDelay(subtitleDelay)
    }

    public func setSubtitleStyle(_ style: MPVSubtitleStyle) {
        subtitleStyle = style
        player.updateSubtitleStyle(style)
    }

    func showPlaybackRatePicker() {
        let alert = actionSheet(title: mpvLocalized("settings.playback_speed"), sourceView: settingsButton)
        [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4].forEach { rate in
            let marker = abs(rate - playbackRate) < 0.001 ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + Self.rateTitle(rate), style: .default) { [weak self] _ in
                self?.setPlaybackRate(rate)
            })
        }
        alert.addAction(UIAlertAction(title: mpvLocalized("common.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func showVideoQualityPicker() {
        let alert = actionSheet(title: mpvLocalized("settings.video_quality"), sourceView: settingsButton)
        [MPVVideoQuality.powerSaving, .balanced, .highQuality].forEach { quality in
            let marker = quality == videoQuality ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + Self.videoQualityTitle(quality), style: .default) { [weak self] _ in
                self?.setVideoQuality(quality)
            })
        }
        alert.addAction(UIAlertAction(title: mpvLocalized("common.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func showInterpolationPicker() {
        let alert = actionSheet(title: mpvLocalized("settings.frame_interpolation"), sourceView: settingsButton)
        MPVInterpolationQuality.allCases.forEach { quality in
            let marker = quality == interpolationOptions.quality ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + Self.interpolationTitle(quality), style: .default) { [weak self] _ in
                guard let self else { return }
                setInterpolationOptions(MPVInterpolationOptions(quality: quality))
            })
        }
        alert.addAction(UIAlertAction(title: mpvLocalized("common.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func showSubtitleDelayPicker() {
        let alert = actionSheet(title: mpvLocalized("subtitle.delay"), sourceView: settingsButton)
        [-2.0, -1, -0.5, 0, 0.5, 1, 2].forEach { delay in
            let marker = abs(delay - subtitleDelay) < 0.001 ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + Self.delayTitle(delay), style: .default) { [weak self] _ in
                self?.setSubtitleDelay(delay)
            })
        }
        alert.addAction(UIAlertAction(title: mpvLocalized("common.custom"), style: .default) { [weak self] _ in
            self?.presentAfterCurrentSheet { $0.showCustomSubtitleDelayPrompt() }
        })
        alert.addAction(UIAlertAction(title: mpvLocalized("common.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func showCustomSubtitleDelayPrompt() {
        let alert = UIAlertController(
            title: mpvLocalized("subtitle.delay"),
            message: mpvLocalized("subtitle.delay.prompt"),
            preferredStyle: .alert
        )
        alert.addTextField { [subtitleDelay] field in
            field.keyboardType = .numbersAndPunctuation
            field.text = String(format: "%.2f", subtitleDelay)
        }
        alert.addAction(UIAlertAction(title: mpvLocalized("common.apply"), style: .default) { [weak self, weak alert] _ in
            guard let value = alert?.textFields?.first?.text.flatMap(Double.init) else { return }
            self?.setSubtitleDelay(value)
        })
        alert.addAction(UIAlertAction(title: mpvLocalized("common.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func showSubtitleStylePicker() {
        let alert = actionSheet(title: mpvLocalized("subtitle.style"), sourceView: settingsButton)
        let styles: [(String, MPVSubtitleStyle)] = [
            (mpvLocalized("subtitle.style.default"), .defaultStyle),
            (mpvLocalized("subtitle.style.large"), .large),
            (mpvLocalized("subtitle.style.high_contrast"), .highContrast),
        ]
        styles.forEach { title, style in
            let marker = style == subtitleStyle ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + title, style: .default) { [weak self] _ in
                self?.setSubtitleStyle(style)
            })
        }
        alert.addAction(UIAlertAction(title: mpvLocalized("common.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func actionSheet(title: String, sourceView: UIView) -> UIAlertController {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        alert.popoverPresentationController?.sourceView = sourceView
        alert.popoverPresentationController?.sourceRect = sourceView.bounds
        return alert
    }

    func presentAfterCurrentSheet(_ presentation: @escaping (MPVQuickPlayerViewController) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            presentation(self)
        }
    }

    func presentTrackPicker(type: MPVMediaTrackType, sourceView: UIView) {
        let tracks = player.tracks(ofType: type)
        let title: String
        switch type {
        case .video: title = mpvLocalized("track.video")
        case .audio: title = mpvLocalized("track.audio")
        case .subtitle: title = mpvLocalized("track.subtitle")
        }
        let alert = actionSheet(title: title, sourceView: sourceView)

        if type == .subtitle {
            alert.addAction(UIAlertAction(title: mpvLocalized("common.off"), style: .default) { [weak self] _ in
                self?.player.setSubtitlesVisible(false)
            })
            alert.addAction(UIAlertAction(title: mpvLocalized("subtitle.load_external"), style: .default) { [weak self] _ in
                self?.presentAfterCurrentSheet { $0.presentExternalSubtitlePicker() }
            })
            if pendingSubtitleRequestID != nil {
                alert.addAction(UIAlertAction(title: mpvLocalized("subtitle.cancel_load"), style: .destructive) { [weak self] _ in
                    self?.cancelExternalSubtitleLoad()
                })
            }
        }
        for track in tracks {
            let marker = track.isSelected ? "✓ " : ""
            alert.addAction(UIAlertAction(title: marker + track.name, style: .default) { [weak self] _ in
                self?.player.select(track: track)
                if type == .subtitle {
                    self?.player.setSubtitlesVisible(true)
                }
            })
        }
        if tracks.isEmpty {
            alert.message = mpvLocalized("track.none")
        }
        alert.addAction(UIAlertAction(title: mpvLocalized("common.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func presentExternalSubtitlePicker() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.text, .data],
            asCopy: true
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func loadExternalSubtitle(from url: URL, usesOriginalStyle: Bool) {
        loadingIndicator.startAnimating()
        statusLabel.text = mpvLocalized("subtitle.loading")
        pendingSubtitleRequestID = player.loadExternalSubtitle(
            from: url,
            usesOriginalStyle: usesOriginalStyle
        ) { [weak self] success in
            guard let self else { return }
            pendingSubtitleRequestID = nil
            if Self.shouldShowLoading(for: playbackState) {
                loadingIndicator.startAnimating()
            } else {
                loadingIndicator.stopAnimating()
            }
            if success {
                player.setSubtitlesVisible(true)
                updateStatusLabel()
            } else if isCancellingSubtitleLoad == false {
                presentMessage(
                    title: mpvLocalized("subtitle.error.title"),
                    message: mpvLocalized("subtitle.error.message")
                )
            }
            isCancellingSubtitleLoad = false
        }
    }

    func cancelExternalSubtitleLoad() {
        guard let requestID = pendingSubtitleRequestID else { return }
        isCancellingSubtitleLoad = true
        player.cancelExternalSubtitleLoad(requestID)
        pendingSubtitleRequestID = nil
        updateStatusLabel()
    }

    func presentMessage(title: String, message: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: mpvLocalized("common.ok"), style: .default))
        present(alert, animated: true)
    }

}
