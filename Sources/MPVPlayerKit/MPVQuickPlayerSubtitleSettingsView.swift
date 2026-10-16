import UIKit

/// Subtitle settings: delay, style presets, and common style tweaks.
@MainActor
final class MPVQuickPlayerSubtitleSettingsView: MPVQuickPlayerSettingsPanelView {
    private let fontButton = UIButton(type: .system)
    private let styleControl = UISegmentedControl(items: [
        mpvLocalized("subtitle.style.default"),
        mpvLocalized("subtitle.style.large"),
        mpvLocalized("subtitle.style.high_contrast"),
    ])
    private let fontSizeValueLabel = UILabel()
    private let fontSizeStepper = UIStepper()
    private let boldSwitch = UISwitch()
    private let shadowSlider = UISlider()
    private let shadowValueLabel = UILabel()
    private let radiusSlider = UISlider()
    private let radiusValueLabel = UILabel()
    private let radiusNote = UILabel()
    var isShadowRadiusEditable = true {
        didSet {
            radiusSlider.isEnabled = isShadowRadiusEditable
            radiusNote.isHidden = false
        }
    }
    private var style = MPVSubtitleStyle.defaultStyle
    private var delay: TimeInterval = 0

    var onStyleChange: ((MPVSubtitleStyle) -> Void)?
    var onFontTap: ((UIView) -> Void)?
    var onDetailsTap: (() -> Void)?

    override class var cardWidth: CGFloat { 340 }
    override class var cardHeight: CGFloat { 560 }
    override class var titleKey: String { "subtitle.shared_style" }
    override class var accessibilityIdentifierKey: String { "MPVQuickPlayer.subtitleSettings" }

    override func configureContent() {
        let detailsButton = UIButton(type: .system)
        detailsButton.setImage(UIImage(systemName: "info.circle"), for: .normal)
        detailsButton.accessibilityLabel = mpvLocalized("common.details")
        detailsButton.accessibilityIdentifier = "MPVQuickPlayer.subtitleSettingsDetails"
        detailsButton.addAction(UIAction { [weak self] _ in self?.onDetailsTap?() }, for: .touchUpInside)
        titleStack.addArrangedSubview(detailsButton)
        NSLayoutConstraint.activate([
            detailsButton.widthAnchor.constraint(equalToConstant: 44),
            detailsButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        fontButton.setTitle(mpvLocalized("subtitle.font.choose"), for: .normal)
        fontButton.addTarget(self, action: #selector(fontTapped(_:)), for: .touchUpInside)
        contentStack.addArrangedSubview(makeValueButtonRow(title: mpvLocalized("subtitle.font"), button: fontButton))

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

        shadowSlider.minimumValue = 0
        shadowSlider.maximumValue = 100
        shadowSlider.isContinuous = true
        shadowSlider.accessibilityLabel = mpvLocalized("subtitle.shadow_strength")
        shadowSlider.accessibilityIdentifier = "MPVQuickPlayer.subtitleShadowStrength"
        shadowSlider.addTarget(self, action: #selector(shadowChanged(_:)), for: .valueChanged)
        contentStack.addArrangedSubview(makeShadowRow())
        radiusSlider.minimumValue = 0
        radiusSlider.maximumValue = 20
        radiusSlider.isContinuous = true
        radiusSlider.accessibilityLabel = mpvLocalized("subtitle.shadow_radius")
        radiusSlider.accessibilityIdentifier = "MPVQuickPlayer.subtitleShadowRadius"
        radiusSlider.addTarget(self, action: #selector(radiusChanged(_:)), for: .valueChanged)
        contentStack.addArrangedSubview(makeShadowRow(radius: true))
        radiusNote.text = mpvLocalized("subtitle.primary.shadow_radius.note")
        radiusNote.font = .preferredFont(forTextStyle: .footnote)
        radiusNote.textColor = .secondaryLabel
        radiusNote.numberOfLines = 0
        radiusNote.isHidden = false
        contentStack.addArrangedSubview(radiusNote)

        update(style: style, delay: 0)
    }

    func update(style: MPVSubtitleStyle, delay: TimeInterval) {
        self.style = style
        self.delay = delay
        styleControl.selectedSegmentIndex = Self.presetIndex(for: style)
        fontSizeStepper.value = style.fontSize
        fontSizeValueLabel.text = "\(Int(style.fontSize.rounded()))"
        boldSwitch.isOn = style.bold
        let strength = style.shadowOffset / 4
        shadowSlider.value = Float(min(max(strength, 0), 1) * 100)
        let shadowText = mpvLocalized("subtitle.shadow_strength.value", Int(shadowSlider.value.rounded()))
        shadowValueLabel.text = shadowText
        shadowSlider.accessibilityValue = shadowText
        radiusSlider.value = Float(style.shadowRadius)
        let radiusText = String(format: "%.1f pt", style.shadowRadius)
        radiusValueLabel.text = radiusText
        radiusSlider.accessibilityValue = radiusText
    }

    private func makeShadowRow(radius: Bool = false) -> UIView {
        let shadowSlider = radius ? radiusSlider : shadowSlider
        let shadowValueLabel = radius ? radiusValueLabel : shadowValueLabel
        let label = UILabel()
        label.text = mpvLocalized(radius ? "subtitle.primary.shadow_radius" : "subtitle.shadow_strength")
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        shadowValueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        shadowValueLabel.textColor = .label
        shadowValueLabel.textAlignment = .right
        shadowValueLabel.setContentHuggingPriority(.required, for: .horizontal)
        let header = UIStackView(arrangedSubviews: [label, shadowValueLabel])
        header.spacing = 8
        let row = UIStackView(arrangedSubviews: [header, shadowSlider])
        row.axis = .vertical
        row.spacing = 6
        shadowSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
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

    @objc private func fontTapped(_ sender: UIButton) {
        onFontTap?(sender)
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

    @objc private func shadowChanged(_ sender: UISlider) {
        let strength = Double(sender.value) / 100
        var updated = style
        updated.shadowOffset = 4 * strength
        let alpha = strength == 0 ? 0 : 0.15 + 0.85 * strength
        updated.shadowColor = String(format: "#%02X000000", Int((alpha * 255).rounded()))
        applyStyle(updated)
    }

    @objc private func radiusChanged(_ sender: UISlider) {
        guard isShadowRadiusEditable else { return }
        var updated = style
        updated.shadowRadius = Double((sender.value * 2).rounded() / 2)
        applyStyle(updated)
    }

}
