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
    private let displayModeControl = UISegmentedControl(items: [
        mpvLocalized("settings.fit_video"),
        mpvLocalized("settings.fill_screen"),
        mpvLocalized("common.custom"),
    ])
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

        displayModeControl.selectedSegmentIndex = 0
        displayModeControl.addTarget(self, action: #selector(displayModeChanged(_:)), for: .valueChanged)
        contentStack.addArrangedSubview(
            makeSegmentRow(title: mpvLocalized("settings.display_mode"), segmentedControl: displayModeControl)
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
        displayModeControl.selectedSegmentIndex = displayMode.rawValue
        scaleStepper.value = min(max(customScale, 0.5), 3.0)
        scaleValueLabel.text = Self.scaleTitle(customScale)
        let isCustom = displayMode == .custom
        scaleStepper.isEnabled = isCustom
        resetScaleButton.isEnabled = isCustom
        scaleValueLabel.alpha = isCustom ? 1 : 0.45
        scaleStepper.alpha = isCustom ? 1 : 0.45
        resetScaleButton.alpha = isCustom ? 1 : 0.45
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

    @objc private func displayModeChanged(_ sender: UISegmentedControl) {
        guard let mode = MPVVideoDisplayMode(rawValue: sender.selectedSegmentIndex) else { return }
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
