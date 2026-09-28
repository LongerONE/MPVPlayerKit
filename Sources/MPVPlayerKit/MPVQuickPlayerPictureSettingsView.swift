import UIKit

/// Picture settings: quality, debanding, display mode, and custom scale.
@MainActor
final class MPVQuickPlayerPictureSettingsView: MPVQuickPlayerSettingsPanelView {
    private let qualityControl = UISegmentedControl(items: [
        mpvLocalized("quality.power_saver"),
        mpvLocalized("quality.balanced"),
        mpvLocalized("quality.high"),
    ])
    private let debandSwitch = UISwitch()
    private let displayModeControl = UIStackView()
    private var displayModeButtons: [UIButton] = []
    private let scaleValueLabel = UILabel()
    private let scaleStepper = UIStepper()
    private let resetScaleButton = UIButton(type: .system)

    var onQualityChange: ((MPVVideoQuality) -> Void)?
    var onDebandChange: ((Bool) -> Void)?
    var onDisplayModeChange: ((MPVVideoDisplayMode) -> Void)?
    var onScaleChange: ((Double) -> Void)?
    var onResetScaleTap: (() -> Void)?

    override class var cardWidth: CGFloat { 340 }
    override class var cardHeight: CGFloat { 420 }
    override class var titleKey: String { "settings.picture" }
    override class var accessibilityIdentifierKey: String { "MPVQuickPlayer.pictureSettings" }

    override func configureContent() {
        qualityControl.selectedSegmentIndex = 1
        qualityControl.addTarget(self, action: #selector(qualityChanged(_:)), for: .valueChanged)
        contentStack.addArrangedSubview(
            makeSegmentRow(title: mpvLocalized("settings.video_quality"), segmentedControl: qualityControl)
        )

        debandSwitch.addTarget(self, action: #selector(debandChanged(_:)), for: .valueChanged)
        contentStack.addArrangedSubview(
            makeSwitchRow(title: mpvLocalized("settings.debanding"), switchView: debandSwitch)
        )

        configureDisplayModeControl()
        contentStack.addArrangedSubview(
            makeSegmentRow(title: mpvLocalized("settings.display_mode"), control: displayModeControl)
        )

        scaleStepper.minimumValue = 0.5
        scaleStepper.maximumValue = 3.0
        scaleStepper.stepValue = 0.05
        scaleStepper.addTarget(self, action: #selector(scaleStepperChanged(_:)), for: .valueChanged)
        resetScaleButton.setTitle(mpvLocalized("settings.reset_custom_scale"), for: .normal)
        resetScaleButton.addTarget(self, action: #selector(resetScaleTapped), for: .touchUpInside)
        resetScaleButton.accessibilityIdentifier = "MPVQuickPlayer.resetScale"
        contentStack.addArrangedSubview(makeScaleRow())
    }

    func update(
        quality: MPVVideoQuality,
        debandEnabled: Bool,
        displayMode: MPVVideoDisplayMode,
        customScale: Double
    ) {
        qualityControl.selectedSegmentIndex = quality.rawValue
        debandSwitch.isOn = debandEnabled
        updateDisplayModeSelection(displayMode)
        scaleStepper.value = min(max(customScale, 0.5), 3.0)
        scaleValueLabel.text = Self.scaleTitle(customScale)
        let isCustom = displayMode == .custom
        scaleStepper.isEnabled = isCustom
        resetScaleButton.isEnabled = isCustom
        scaleValueLabel.alpha = isCustom ? 1 : 0.45
        scaleStepper.alpha = isCustom ? 1 : 0.45
        resetScaleButton.alpha = isCustom ? 1 : 0.45
    }

    private func configureDisplayModeControl() {
        displayModeControl.axis = .horizontal
        displayModeControl.distribution = .fillEqually
        displayModeControl.spacing = 2
        displayModeControl.isLayoutMarginsRelativeArrangement = true
        displayModeControl.layoutMargins = UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        displayModeControl.backgroundColor = .secondarySystemFill
        displayModeControl.layer.cornerRadius = 10
        displayModeControl.clipsToBounds = true
        displayModeControl.accessibilityIdentifier = "MPVQuickPlayer.displayModeControl"

        let options: [(MPVVideoDisplayMode, MPVQuickPlayerSymbol, String)] = [
            (.fit, .displayFit, mpvLocalized("settings.fit_video")),
            (.fill, .zoom, mpvLocalized("settings.fill_screen")),
            (.custom, .displayCustom, mpvLocalized("common.custom")),
        ]
        for (mode, symbol, title) in options {
            var configuration = UIButton.Configuration.plain()
            configuration.title = title
            configuration.image = MPVQuickPlayerSymbol.image(
                symbol,
                pointSize: 14,
                weight: .medium,
                scale: .small
            )
            configuration.imagePlacement = .leading
            configuration.imagePadding = 4
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 6,
                leading: 2,
                bottom: 6,
                trailing: 2
            )

            let button = UIButton(type: .system)
            button.configuration = configuration
            button.tag = mode.rawValue
            button.layer.cornerRadius = 7
            button.clipsToBounds = true
            button.accessibilityLabel = title
            button.accessibilityIdentifier = "MPVQuickPlayer.displayMode.\(mode.rawValue)"
            button.configurationUpdateHandler = { button in
                var updatedConfiguration = button.configuration
                updatedConfiguration?.baseForegroundColor = button.isSelected ? .label : .secondaryLabel
                var background = UIBackgroundConfiguration.clear()
                if button.isSelected {
                    background.backgroundColor = .systemBackground
                    background.cornerRadius = 7
                }
                updatedConfiguration?.background = background
                button.configuration = updatedConfiguration
            }
            button.addTarget(self, action: #selector(displayModeButtonTapped(_:)), for: .touchUpInside)
            displayModeButtons.append(button)
            displayModeControl.addArrangedSubview(button)
        }
        updateDisplayModeSelection(.fit)
    }

    private func updateDisplayModeSelection(_ mode: MPVVideoDisplayMode) {
        for button in displayModeButtons {
            button.isSelected = button.tag == mode.rawValue
            button.accessibilityTraits = button.isSelected ? [.button, .selected] : [.button]
            button.setNeedsUpdateConfiguration()
        }
    }

    static func scaleTitle(_ scale: Double) -> String {
        mpvLocalized("settings.custom_scale.value", Int((scale * 100).rounded()))
    }

    private func makeScaleRow() -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = mpvLocalized("settings.custom_scale")
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        scaleValueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        scaleValueLabel.textColor = .label
        scaleValueLabel.textAlignment = .right
        scaleValueLabel.setContentHuggingPriority(.required, for: .horizontal)
        row.addSubview(label)
        row.addSubview(scaleValueLabel)
        row.addSubview(scaleStepper)
        row.addSubview(resetScaleButton)
        label.translatesAutoresizingMaskIntoConstraints = false
        scaleValueLabel.translatesAutoresizingMaskIntoConstraints = false
        scaleStepper.translatesAutoresizingMaskIntoConstraints = false
        resetScaleButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            resetScaleButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            resetScaleButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            scaleValueLabel.trailingAnchor.constraint(equalTo: resetScaleButton.leadingAnchor, constant: -8),
            scaleValueLabel.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            scaleStepper.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            scaleStepper.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            scaleStepper.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: scaleValueLabel.leadingAnchor, constant: -8),
        ])
        return row
    }

    @objc private func qualityChanged(_ sender: UISegmentedControl) {
        guard let quality = MPVVideoQuality(rawValue: sender.selectedSegmentIndex) else { return }
        onQualityChange?(quality)
    }

    @objc private func debandChanged(_ sender: UISwitch) {
        onDebandChange?(sender.isOn)
    }

    @objc private func displayModeButtonTapped(_ sender: UIButton) {
        guard let mode = MPVVideoDisplayMode(rawValue: sender.tag) else { return }
        updateDisplayModeSelection(mode)
        onDisplayModeChange?(mode)
    }

    @objc private func scaleStepperChanged(_ sender: UIStepper) {
        scaleValueLabel.text = Self.scaleTitle(sender.value)
        onScaleChange?(sender.value)
    }

    @objc private func resetScaleTapped() {
        onResetScaleTap?()
    }
}
