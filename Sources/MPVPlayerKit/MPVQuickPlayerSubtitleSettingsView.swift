import UIKit

/// Subtitle settings: delay, style presets, and common style tweaks.
@MainActor
final class MPVQuickPlayerSubtitleSettingsView: MPVQuickPlayerSettingsPanelView {
    private let delayButton = UIButton(type: .system)
    private let styleControl = UISegmentedControl(items: [
        mpvLocalized("subtitle.style.default"),
        mpvLocalized("subtitle.style.large"),
        mpvLocalized("subtitle.style.high_contrast"),
    ])
    private let fontSizeValueLabel = UILabel()
    private let fontSizeStepper = UIStepper()
    private let boldSwitch = UISwitch()
    private let bottomOffsetValueLabel = UILabel()
    private let bottomOffsetStepper = UIStepper()
    private var style = MPVSubtitleStyle.defaultStyle
    private var delay: TimeInterval = 0

    var onStyleChange: ((MPVSubtitleStyle) -> Void)?
    var onDelayTap: ((UIView) -> Void)?

    override class var cardWidth: CGFloat { 340 }
    override class var cardHeight: CGFloat { 460 }
    override class var titleKey: String { "settings.subtitle" }
    override class var accessibilityIdentifierKey: String { "MPVQuickPlayer.subtitleSettings" }

    override func configureContent() {
        delayButton.accessibilityIdentifier = "MPVQuickPlayer.subtitleDelay"
        delayButton.addTarget(self, action: #selector(delayTapped(_:)), for: .touchUpInside)
        contentStack.addArrangedSubview(
            makeValueButtonRow(title: mpvLocalized("subtitle.delay"), button: delayButton)
        )

        styleControl.addTarget(self, action: #selector(stylePresetChanged(_:)), for: .valueChanged)
        contentStack.addArrangedSubview(
            makeSegmentRow(title: mpvLocalized("subtitle.style"), segmentedControl: styleControl)
        )

        fontSizeStepper.minimumValue = 8
        fontSizeStepper.maximumValue = 120
        fontSizeStepper.stepValue = 1
        fontSizeStepper.addTarget(self, action: #selector(fontSizeChanged(_:)), for: .valueChanged)
        contentStack.addArrangedSubview(
            makeStepperRow(
                title: mpvLocalized("subtitle.font_size"),
                valueLabel: fontSizeValueLabel,
                stepper: fontSizeStepper
            )
        )

        boldSwitch.addTarget(self, action: #selector(boldChanged(_:)), for: .valueChanged)
        contentStack.addArrangedSubview(
            makeSwitchRow(title: mpvLocalized("subtitle.bold"), switchView: boldSwitch)
        )

        bottomOffsetStepper.minimumValue = 0
        bottomOffsetStepper.maximumValue = 300
        bottomOffsetStepper.stepValue = 2
        bottomOffsetStepper.addTarget(self, action: #selector(bottomOffsetChanged(_:)), for: .valueChanged)
        contentStack.addArrangedSubview(
            makeStepperRow(
                title: mpvLocalized("subtitle.bottom_offset"),
                valueLabel: bottomOffsetValueLabel,
                stepper: bottomOffsetStepper
            )
        )

        update(style: style, delay: 0)
    }

    func update(style: MPVSubtitleStyle, delay: TimeInterval) {
        self.style = style
        self.delay = delay
        let delayText = MPVQuickPlayerViewController.delayTitle(delay)
        delayButton.setTitle(delayText, for: .normal)
        delayButton.accessibilityValue = delayText
        styleControl.selectedSegmentIndex = Self.presetIndex(for: style)
        fontSizeStepper.value = style.fontSize
        fontSizeValueLabel.text = "\(Int(style.fontSize.rounded()))"
        boldSwitch.isOn = style.bold
        bottomOffsetStepper.value = style.bottomOffset
        bottomOffsetValueLabel.text = "\(Int(style.bottomOffset.rounded()))"
    }

    private static func presetIndex(for style: MPVSubtitleStyle) -> Int {
        if style == .defaultStyle { return 0 }
        if style == .large { return 1 }
        if style == .highContrast { return 2 }
        return UISegmentedControl.noSegment
    }

    private static func preset(at index: Int) -> MPVSubtitleStyle? {
        switch index {
        case 0: return .defaultStyle
        case 1: return .large
        case 2: return .highContrast
        default: return nil
        }
    }

    private func applyStyle(_ style: MPVSubtitleStyle) {
        self.style = style
        onStyleChange?(style)
        update(style: style, delay: delay)
    }

    @objc private func delayTapped(_ sender: UIButton) {
        onDelayTap?(sender)
    }

    @objc private func stylePresetChanged(_ sender: UISegmentedControl) {
        guard let preset = Self.preset(at: sender.selectedSegmentIndex) else { return }
        applyStyle(preset)
    }

    @objc private func fontSizeChanged(_ sender: UIStepper) {
        var updated = style
        updated.fontSize = sender.value
        applyStyle(updated)
    }

    @objc private func boldChanged(_ sender: UISwitch) {
        var updated = style
        updated.bold = sender.isOn
        applyStyle(updated)
    }

    @objc private func bottomOffsetChanged(_ sender: UIStepper) {
        var updated = style
        updated.bottomOffset = sender.value
        applyStyle(updated)
    }
}
