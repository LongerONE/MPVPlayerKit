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
        presentInPlayerOrientation(alert)
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
        presentInPlayerOrientation(alert)
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
        presentInPlayerOrientation(alert)
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
        presentInPlayerOrientation(alert)
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
        presentInPlayerOrientation(alert)
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
        presentInPlayerOrientation(alert)
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

        if isUsingManualLandscape && isLandscapeForced {
            presentManualLandscapeTrackPicker(title: title, tracks: tracks, type: type)
            return
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
        presentInPlayerOrientation(alert)
    }

    private func presentManualLandscapeTrackPicker(
        title: String,
        tracks: [MPVMediaTrack],
        type: MPVMediaTrackType
    ) {
        var options: [MPVLandscapeTrackPickerViewController.Option] = []
        if type == .subtitle {
            options.append(.init(title: mpvLocalized("common.off")) { [weak self] in
                self?.player.setSubtitlesVisible(false)
            })
            options.append(.init(title: mpvLocalized("subtitle.load_external")) { [weak self] in
                self?.presentAfterCurrentSheet { $0.presentExternalSubtitlePicker() }
            })
            if pendingSubtitleRequestID != nil {
                options.append(.init(title: mpvLocalized("subtitle.cancel_load"), isDestructive: true) {
                    [weak self] in
                    self?.cancelExternalSubtitleLoad()
                })
            }
        }
        options += tracks.map { track in
            .init(title: track.name, isSelected: track.isSelected) { [weak self] in
                self?.player.select(track: track)
                if type == .subtitle {
                    self?.player.setSubtitlesVisible(true)
                }
            }
        }

        let picker = MPVLandscapeTrackPickerViewController(
            title: title,
            message: tracks.isEmpty ? mpvLocalized("track.none") : nil,
            options: options,
            cancelTitle: mpvLocalized("common.cancel")
        )
        presentInPlayerOrientation(picker)
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

@MainActor
final class MPVLandscapeTrackPickerViewController: UIViewController {
    struct Option {
        let title: String
        let isSelected: Bool
        let isDestructive: Bool
        let action: () -> Void

        init(
            title: String,
            isSelected: Bool = false,
            isDestructive: Bool = false,
            action: @escaping () -> Void
        ) {
            self.title = title
            self.isSelected = isSelected
            self.isDestructive = isDestructive
            self.action = action
        }
    }

    let cardView = UIView()
    let tableView = UITableView(frame: .zero, style: .plain)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let options: [Option]
    private let message: String?

    init(title: String, message: String?, options: [Option], cancelTitle: String) {
        self.options = options
        self.message = message
        super.init(nibName: nil, bundle: nil)
        titleLabel.text = title
        cancelButton.setTitle(cancelTitle, for: .normal)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        configureLayout()
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.55)

        cardView.backgroundColor = .secondarySystemBackground
        cardView.layer.cornerRadius = 18
        cardView.layer.cornerCurve = .continuous
        cardView.clipsToBounds = true
        view.addSubview(cardView)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        cardView.addSubview(titleLabel)

        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textAlignment = .center
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.text = message
        messageLabel.isHidden = message == nil
        cardView.addSubview(messageLabel)

        tableView.backgroundColor = .clear
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tableView.estimatedRowHeight = 54
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "TrackOption")
        tableView.dataSource = self
        tableView.delegate = self
        cardView.addSubview(tableView)

        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        cardView.addSubview(cancelButton)
    }

    private func configureLayout() {
        [cardView, titleLabel, messageLabel, tableView, cancelButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        let guide = view.safeAreaLayoutGuide
        let preferredCardWidth = cardView.widthAnchor.constraint(
            equalTo: guide.widthAnchor,
            multiplier: 0.88
        )
        preferredCardWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            preferredCardWidth,
            cardView.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 16),
            cardView.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -16),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),

            tableView.topAnchor.constraint(
                equalTo: message == nil ? titleLabel.bottomAnchor : messageLabel.bottomAnchor,
                constant: 12
            ),
            tableView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            tableView.heightAnchor.constraint(lessThanOrEqualToConstant: 240),
            tableView.heightAnchor.constraint(equalToConstant: options.isEmpty ? 0 : 180),

            cancelButton.topAnchor.constraint(equalTo: tableView.bottomAnchor, constant: 8),
            cancelButton.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
        ])
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }
}

extension MPVLandscapeTrackPickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        options.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let option = options[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "TrackOption", for: indexPath)
        var content = UIListContentConfiguration.cell()
        content.text = option.title
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.numberOfLines = 0
        content.textProperties.lineBreakMode = .byWordWrapping
        content.textProperties.color = option.isDestructive ? .systemRed : .label
        cell.contentConfiguration = content
        cell.accessoryType = option.isSelected ? .checkmark : .none
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let action = options[indexPath.row].action
        dismiss(animated: true, completion: action)
    }
}
