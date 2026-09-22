import MediaPlayer
import UIKit
import UniformTypeIdentifiers

extension MPVQuickPlayerViewController {
    @objc func showSettings() {
        let options: [MPVQuickPlayerActionSheetOption] = [
            .init(
                title: mpvLocalized("settings.playback_speed.value", Self.rateTitle(playbackRate)),
                symbol: .playbackSpeed
            ) { [weak self] in
                self?.presentAfterCurrentSheet { $0.showPlaybackRatePicker() }
            },
            .init(title: mpvLocalized("settings.picture"), symbol: .pictureSettings) {
                [weak self] in self?.presentAfterCurrentSheet { $0.showPictureSettings() }
            },
            .init(title: mpvLocalized("settings.subtitle"), symbol: .subtitles) {
                [weak self] in self?.presentAfterCurrentSheet { $0.showSubtitleSettings() }
            },
            .init(title: mpvLocalized("settings.cache"), symbol: .cache) {
                [weak self] in self?.presentAfterCurrentSheet { $0.showCacheSettings() }
            },
        ]
        presentActionSheet(
            title: mpvLocalized("settings.title"),
            sourceView: settingsButton,
            options: options,
            cancelTitle: mpvLocalized("common.cancel")
        )
    }

    public func setPlaybackRate(_ rate: Double) {
        let normalizedRate = min(max(rate, 0.25), 4.0)
        playbackRate = normalizedRate
        player.setPlaybackRate(normalizedRate)
        updateStatusLabel()
    }

    public func setVideoDisplayMode(_ mode: MPVVideoDisplayMode) {
        player.videoDisplayMode = mode
    }

    public func setCustomVideoScale(_ scale: Double) {
        player.customVideoScale = scale
    }

    public func resetCustomVideoScale() {
        player.resetCustomVideoScale()
    }

    public func setVideoQuality(_ quality: MPVVideoQuality) {
        videoQuality = quality
        player.updateVideoQuality(quality)
    }

    public func setDebandEnabled(_ enabled: Bool) {
        debandEnabled = enabled
        player.updateVideoRenderOptions(debandEnabled: enabled)
    }

    public func setCacheConfiguration(_ configuration: MPVCacheConfiguration) {
        cacheConfiguration = configuration
        MPVCachePreferences.save(configuration)
        player.setCacheConfiguration(configuration)
    }

    func showCacheSettings() {
        let settingsView = MPVQuickPlayerCacheSettingsView(configuration: cacheConfiguration)
        settingsView.onChange = { [weak self, weak settingsView] configuration in
            self?.setCacheConfiguration(configuration)
            settingsView?.update(configuration: configuration)
        }
        settingsView.onDurationTap = { [weak self, weak settingsView] sourceView in
            self?.showCacheDurationPicker(from: sourceView, settingsView: settingsView)
        }
        settingsView.onDismiss = { [weak self, weak settingsView] in
            guard let self, settingsPanelOverlay === settingsView else { return }
            settingsPanelOverlay = nil
        }
        presentSettingsPanel(settingsView)
    }

    func showPictureSettings() {
        let settingsView = MPVQuickPlayerPictureSettingsView()
        settingsView.onQualityChange = { [weak self, weak settingsView] quality in
            guard let self else { return }
            setVideoQuality(quality)
            settingsView?.update(
                quality: videoQuality,
                debandEnabled: debandEnabled,
                displayMode: player.videoDisplayMode,
                customScale: player.customVideoScale
            )
        }
        settingsView.onDebandChange = { [weak self, weak settingsView] enabled in
            guard let self else { return }
            setDebandEnabled(enabled)
            settingsView?.update(
                quality: videoQuality,
                debandEnabled: debandEnabled,
                displayMode: player.videoDisplayMode,
                customScale: player.customVideoScale
            )
        }
        settingsView.onDisplayModeChange = { [weak self, weak settingsView] mode in
            guard let self else { return }
            setVideoDisplayMode(mode)
            settingsView?.update(
                quality: videoQuality,
                debandEnabled: debandEnabled,
                displayMode: player.videoDisplayMode,
                customScale: player.customVideoScale
            )
        }
        settingsView.onScaleChange = { [weak self, weak settingsView] scale in
            guard let self else { return }
            setCustomVideoScale(scale)
            if player.videoDisplayMode != .custom {
                setVideoDisplayMode(.custom)
            }
            settingsView?.update(
                quality: videoQuality,
                debandEnabled: debandEnabled,
                displayMode: player.videoDisplayMode,
                customScale: player.customVideoScale
            )
        }
        settingsView.onResetScaleTap = { [weak self, weak settingsView] in
            guard let self else { return }
            resetCustomVideoScale()
            settingsView?.update(
                quality: videoQuality,
                debandEnabled: debandEnabled,
                displayMode: player.videoDisplayMode,
                customScale: player.customVideoScale
            )
        }
        settingsView.onDismiss = { [weak self, weak settingsView] in
            guard let self, settingsPanelOverlay === settingsView else { return }
            settingsPanelOverlay = nil
        }
        settingsView.update(
            quality: videoQuality,
            debandEnabled: debandEnabled,
            displayMode: player.videoDisplayMode,
            customScale: player.customVideoScale
        )
        presentSettingsPanel(settingsView)
    }

    func showSubtitleSettings() {
        let settingsView = MPVQuickPlayerSubtitleSettingsView()
        settingsView.onStyleChange = { [weak self] style in
            self?.setSubtitleStyle(style)
        }
        settingsView.onDelayTap = { [weak self, weak settingsView] sourceView in
            self?.showSubtitleDelayPicker(from: sourceView, settingsView: settingsView)
        }
        settingsView.onDismiss = { [weak self, weak settingsView] in
            guard let self, settingsPanelOverlay === settingsView else { return }
            settingsPanelOverlay = nil
        }
        settingsView.update(style: subtitleStyle, delay: subtitleDelay)
        presentSettingsPanel(settingsView)
    }

    private func showCacheDurationPicker(
        from sourceView: UIView,
        settingsView: MPVQuickPlayerCacheSettingsView?
    ) {
        let options = MPVCacheConfiguration.availableDurations.map { duration in
            MPVQuickPlayerActionSheetOption(
                title: MPVQuickPlayerCacheSettingsView.durationTitle(for: duration),
                isSelected: abs(duration - cacheConfiguration.duration) < 0.001
            ) { [weak self, weak settingsView] in
                guard let self else { return }
                var configuration = cacheConfiguration
                configuration.duration = duration
                setCacheConfiguration(configuration)
                settingsView?.update(configuration: configuration)
            }
        }
        presentActionSheet(
            title: mpvLocalized("cache.duration"),
            sourceView: sourceView,
            options: options,
            cancelTitle: mpvLocalized("common.cancel")
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
        let options = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4].map { rate in
            let marker = abs(rate - playbackRate) < 0.001 ? "✓ " : ""
            return MPVQuickPlayerActionSheetOption(
                title: marker + Self.rateTitle(rate),
                action: { [weak self] in self?.setPlaybackRate(rate) }
            )
        }
        presentActionSheet(
            title: mpvLocalized("settings.playback_speed"),
            sourceView: settingsButton,
            options: options,
            cancelTitle: mpvLocalized("common.cancel")
        )
    }

    func showSubtitleDelayPicker(
        from sourceView: UIView,
        settingsView: MPVQuickPlayerSubtitleSettingsView?
    ) {
        var options = [-2.0, -1, -0.5, 0, 0.5, 1, 2].map { delay in
            let marker = abs(delay - subtitleDelay) < 0.001 ? "✓ " : ""
            return MPVQuickPlayerActionSheetOption(
                title: marker + Self.delayTitle(delay),
                action: { [weak self, weak settingsView] in
                    guard let self else { return }
                    setSubtitleDelay(delay)
                    settingsView?.update(style: subtitleStyle, delay: subtitleDelay)
                }
            )
        }
        options.append(.init(title: mpvLocalized("common.custom")) { [weak self, weak settingsView] in
            self?.presentAfterCurrentSheet {
                $0.showCustomSubtitleDelayPrompt(settingsView: settingsView)
            }
        })
        presentActionSheet(
            title: mpvLocalized("subtitle.delay"),
            sourceView: sourceView,
            options: options,
            cancelTitle: mpvLocalized("common.cancel")
        )
    }

    func showCustomSubtitleDelayPrompt(settingsView: MPVQuickPlayerSubtitleSettingsView?) {
        let alert = UIAlertController(
            title: mpvLocalized("subtitle.delay"),
            message: mpvLocalized("subtitle.delay.prompt"),
            preferredStyle: .alert
        )
        alert.addTextField { [subtitleDelay] field in
            field.keyboardType = .numbersAndPunctuation
            field.text = String(format: "%.2f", subtitleDelay)
        }
        alert.addAction(UIAlertAction(title: mpvLocalized("common.apply"), style: .default) {
            [weak self, weak alert, weak settingsView] _ in
            guard let self, let value = alert?.textFields?.first?.text.flatMap(Double.init) else { return }
            setSubtitleDelay(value)
            settingsView?.update(style: subtitleStyle, delay: subtitleDelay)
        })
        alert.addAction(UIAlertAction(title: mpvLocalized("common.cancel"), style: .cancel))
        presentInPlayerOrientation(alert)
    }

    func presentActionSheet(
        title: String,
        message: String? = nil,
        sourceView: UIView,
        options: [MPVQuickPlayerActionSheetOption],
        cancelTitle: String
    ) {
        dismissActionSheet(animated: false)

        // Resolve the player geometry before installing the overlay. The menu is
        // a child of contentView, so no presentation-time rotation is needed.
        layoutOrientationContentView()
        updatePlaybackControlSafeAreaInsets()
        view.layoutIfNeeded()
        contentView.layoutIfNeeded()

        let menu = MPVQuickPlayerMenuView(
            title: title,
            message: message,
            options: options,
            cancelTitle: cancelTitle,
            sourceView: sourceView
        )
        menu.onDismiss = { [weak self, weak menu] in
            guard let self, actionSheetOverlay === menu else { return }
            actionSheetOverlay = nil
        }
        actionSheetOverlay = menu
        contentView.addSubview(menu)
        NSLayoutConstraint.activate([
            menu.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            menu.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            menu.topAnchor.constraint(equalTo: contentView.topAnchor),
            menu.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        menu.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
        contentView.layoutIfNeeded()
    }

    func presentSettingsPanel(_ settingsView: UIView & MPVQuickPlayerPanelOverlay) {
        dismissActionSheet(animated: false)
        settingsPanelOverlay?.dismiss(animated: false)
        layoutOrientationContentView()
        updatePlaybackControlSafeAreaInsets()
        view.layoutIfNeeded()
        contentView.layoutIfNeeded()
        settingsPanelOverlay = settingsView
        contentView.addSubview(settingsView)
        settingsView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            settingsView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            settingsView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            settingsView.topAnchor.constraint(equalTo: contentView.topAnchor),
            settingsView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        settingsView.updatePlayerSafeAreaInsets(playerOrientationSafeAreaInsets())
        contentView.layoutIfNeeded()
    }

    func presentAfterCurrentSheet(_ presentation: @escaping (MPVQuickPlayerViewController) -> Void) {
        guard let menu = actionSheetOverlay else {
            presentation(self)
            return
        }
        menu.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            presentation(self)
        }
    }

    func dismissActionSheet(animated: Bool, completion: (() -> Void)? = nil) {
        guard let menu = actionSheetOverlay else {
            completion?()
            return
        }
        menu.dismiss(animated: animated, completion: completion)
    }

    func presentTrackPicker(type: MPVMediaTrackType, sourceView: UIView) {
        let tracks = player.tracks(ofType: type)
        let title: String
        switch type {
        case .video: title = mpvLocalized("track.video")
        case .audio: title = mpvLocalized("track.audio")
        case .subtitle: title = mpvLocalized("track.subtitle")
        }

        var options: [MPVQuickPlayerActionSheetOption] = []
        if type == .subtitle {
            options.append(.init(title: mpvLocalized("common.off")) { [weak self] in
                self?.player.setSubtitlesVisible(false)
            })
            options.append(.init(title: mpvLocalized("subtitle.load_external")) { [weak self] in
                self?.presentAfterCurrentSheet { $0.presentExternalSubtitlePicker() }
            })
            if pendingSubtitleRequestID != nil {
                options.append(.init(title: mpvLocalized("subtitle.cancel_load"), isDestructive: true) { [weak self] in
                    self?.cancelExternalSubtitleLoad()
                })
            }
        }
        options += tracks.map { track in
            MPVQuickPlayerActionSheetOption(title: track.name, isSelected: track.isSelected) { [weak self] in
                self?.player.select(track: track)
                if type == .subtitle {
                    self?.player.setSubtitlesVisible(true)
                }
            }
        }
        presentActionSheet(
            title: title,
            message: tracks.isEmpty ? mpvLocalized("track.none") : nil,
            sourceView: sourceView,
            options: options,
            cancelTitle: mpvLocalized("common.cancel")
        )
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
        presentInPlayerOrientation(alert)
    }

}
