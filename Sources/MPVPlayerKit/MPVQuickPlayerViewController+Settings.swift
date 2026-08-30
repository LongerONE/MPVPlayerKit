import MediaPlayer
import UIKit
import UniformTypeIdentifiers

extension MPVQuickPlayerViewController {
    @objc func showSettings() {
        var options: [MPVQuickPlayerActionSheetOption] = [
            .init(title: mpvLocalized("settings.playback_speed.value", Self.rateTitle(playbackRate))) {
                [weak self] in self?.presentAfterCurrentSheet { $0.showPlaybackRatePicker() }
            },
            .init(title: mpvLocalized("settings.video_quality.value", Self.videoQualityTitle(videoQuality))) {
                [weak self] in self?.presentAfterCurrentSheet { $0.showVideoQualityPicker() }
            },
        ]
        options.append(.init(
            title: mpvLocalized("settings.cache"),
            symbol: .cache
        ) { [weak self] in
            self?.presentAfterCurrentSheet { $0.showCacheSettings() }
        })
        let debandTitle = mpvLocalized(
            debandEnabled ? "settings.disable_debanding" : "settings.enable_debanding"
        )
        options.append(.init(title: debandTitle) { [weak self] in
            guard let self else { return }
            setDebandEnabled(debandEnabled == false)
        })
        let contentModeTitle = mpvLocalized(
            player.contentMode == .scaleAspectFill ? "settings.fit_video" : "settings.fill_screen"
        )
        options.append(.init(title: contentModeTitle) { [weak self] in
            guard let self else { return }
            player.contentMode = player.contentMode == .scaleAspectFill ? .scaleAspectFit : .scaleAspectFill
        })
        options.append(.init(title: mpvLocalized("subtitle.delay.value", Self.delayTitle(subtitleDelay))) {
            [weak self] in self?.presentAfterCurrentSheet { $0.showSubtitleDelayPicker() }
        })
        options.append(.init(title: mpvLocalized("subtitle.style")) {
            [weak self] in self?.presentAfterCurrentSheet { $0.showSubtitleStylePicker() }
        })
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
            guard let self, cacheSettingsOverlay === settingsView else { return }
            cacheSettingsOverlay = nil
        }
        presentCacheSettingsOverlay(settingsView)
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

    func showVideoQualityPicker() {
        let options = [MPVVideoQuality.powerSaving, .balanced, .highQuality].map { quality in
            let marker = quality == videoQuality ? "✓ " : ""
            return MPVQuickPlayerActionSheetOption(
                title: marker + Self.videoQualityTitle(quality),
                action: { [weak self] in self?.setVideoQuality(quality) }
            )
        }
        presentActionSheet(
            title: mpvLocalized("settings.video_quality"),
            sourceView: settingsButton,
            options: options,
            cancelTitle: mpvLocalized("common.cancel")
        )
    }

    func showSubtitleDelayPicker() {
        var options = [-2.0, -1, -0.5, 0, 0.5, 1, 2].map { delay in
            let marker = abs(delay - subtitleDelay) < 0.001 ? "✓ " : ""
            return MPVQuickPlayerActionSheetOption(
                title: marker + Self.delayTitle(delay),
                action: { [weak self] in self?.setSubtitleDelay(delay) }
            )
        }
        options.append(.init(title: mpvLocalized("common.custom")) { [weak self] in
            self?.presentAfterCurrentSheet { $0.showCustomSubtitleDelayPrompt() }
        })
        presentActionSheet(
            title: mpvLocalized("subtitle.delay"),
            sourceView: settingsButton,
            options: options,
            cancelTitle: mpvLocalized("common.cancel")
        )
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
        presentInPlayerOrientation(alert)
    }

    func showSubtitleStylePicker() {
        let styles: [(String, MPVSubtitleStyle)] = [
            (mpvLocalized("subtitle.style.default"), .defaultStyle),
            (mpvLocalized("subtitle.style.large"), .large),
            (mpvLocalized("subtitle.style.high_contrast"), .highContrast),
        ]
        let options = styles.map { title, style in
            let marker = style == subtitleStyle ? "✓ " : ""
            return MPVQuickPlayerActionSheetOption(
                title: marker + title,
                action: { [weak self] in self?.setSubtitleStyle(style) }
            )
        }
        presentActionSheet(
            title: mpvLocalized("subtitle.style"),
            sourceView: settingsButton,
            options: options,
            cancelTitle: mpvLocalized("common.cancel")
        )
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

    func presentCacheSettingsOverlay(_ settingsView: MPVQuickPlayerCacheSettingsView) {
        dismissActionSheet(animated: false)
        layoutOrientationContentView()
        updatePlaybackControlSafeAreaInsets()
        view.layoutIfNeeded()
        contentView.layoutIfNeeded()
        cacheSettingsOverlay = settingsView
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
