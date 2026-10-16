import UIKit

@MainActor
final class MPVQuickPlayerSubtitleControlView: MPVQuickPlayerSettingsPanelView {
    let sourceButton = UIButton(type: .system)
    private let delayStepper = UIStepper()
    private let delayLabel = UILabel()
    private let positionSlider = UISlider()
    private let positionLabel = UILabel()
    private let positionPresets = UISegmentedControl(items: [
        mpvLocalized("subtitle.position.top"), mpvLocalized("subtitle.position.bottom"),
    ])
    private let originalSwitch = UISwitch()
    private let automaticSwitch = UISwitch()
    private let languageControl = UISegmentedControl(items: [
        mpvLocalized("subtitle.language.simplified"),
        mpvLocalized("subtitle.language.traditional"),
        mpvLocalized("subtitle.language.english"),
    ])
    private let resetButton = UIButton(type: .system)
    private let note = UILabel()
    var onSource: ((UIView) -> Void)?
    var onDelay: ((TimeInterval) -> Void)?
    var onPosition: ((Double) -> Void)?
    var onOriginalStyle: ((Bool) -> Void)?
    var onAutomatic: ((Bool) -> Void)?
    var onLanguage: ((MPVSubtitleLanguage) -> Void)?
    var onReset: (() -> Void)?

    override class var cardWidth: CGFloat { 360 }
    override class var cardHeight: CGFloat { 620 }
    override class var accessibilityIdentifierKey: String { "MPVQuickPlayer.subtitleControl" }

    override func configureContent() {
        sourceButton.addTarget(self, action: #selector(sourceTapped), for: .touchUpInside)
        sourceButton.accessibilityIdentifier = "MPVQuickPlayer.subtitleSource"
        sourceButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        contentStack.addArrangedSubview(makeValueButtonRow(title: mpvLocalized("subtitle.source"), button: sourceButton))
        let delayRow = makeStepperRow(title: mpvLocalized("subtitle.delay"), valueLabel: delayLabel, stepper: delayStepper)
        delayStepper.minimumValue = -60
        delayStepper.maximumValue = 60
        delayStepper.stepValue = 0.1
        delayStepper.accessibilityIdentifier = "MPVQuickPlayer.subtitleDelay"
        delayStepper.accessibilityLabel = mpvLocalized("subtitle.delay")
        delayStepper.addTarget(self, action: #selector(delayChanged), for: .valueChanged)
        contentStack.addArrangedSubview(delayRow)
        positionSlider.minimumValue = 0
        positionSlider.maximumValue = 150
        positionSlider.accessibilityLabel = mpvLocalized("subtitle.position")
        positionSlider.accessibilityIdentifier = "MPVQuickPlayer.subtitlePosition"
        positionSlider.addTarget(self, action: #selector(positionChanged), for: .valueChanged)
        positionSlider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        positionLabel.font = .preferredFont(forTextStyle: .body)
        positionLabel.adjustsFontForContentSizeCategory = true
        positionLabel.textColor = .label
        let positionRow = UIStackView(arrangedSubviews: [positionLabel, positionSlider, positionPresets])
        positionRow.axis = .vertical
        positionRow.spacing = 6
        positionPresets.addTarget(self, action: #selector(positionPresetChanged), for: .valueChanged)
        contentStack.addArrangedSubview(positionRow)
        originalSwitch.addTarget(self, action: #selector(originalChanged), for: .valueChanged)
        contentStack.addArrangedSubview(makeSwitchRow(title: mpvLocalized("subtitle.original_ass"), switchView: originalSwitch))
        automaticSwitch.addTarget(self, action: #selector(automaticChanged), for: .valueChanged)
        contentStack.addArrangedSubview(makeSwitchRow(title: mpvLocalized("subtitle.automatic"), switchView: automaticSwitch))
        languageControl.addTarget(self, action: #selector(languageChanged), for: .valueChanged)
        languageControl.accessibilityLabel = mpvLocalized("subtitle.language")
        contentStack.addArrangedSubview(makeSegmentRow(title: mpvLocalized("subtitle.language"), segmentedControl: languageControl))
        note.font = .preferredFont(forTextStyle: .footnote)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        contentStack.addArrangedSubview(note)
        resetButton.setTitle(mpvLocalized("subtitle.reset_control"), for: .normal)
        resetButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        resetButton.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
        contentStack.addArrangedSubview(resetButton)
    }

    func update(slot: MPVSubtitleSlot, state: MPVSubtitleState,
                control: MPVQuickPlayerSubtitlePreferences.Control, source: String, usesOriginalASS: Bool) {
        titleLabel.text = mpvLocalized(slot == .primary ? "subtitle.primary" : "subtitle.secondary")
        sourceButton.setTitle(source, for: .normal)
        sourceButton.accessibilityLabel = mpvLocalized("subtitle.source")
        sourceButton.accessibilityValue = source
        delayStepper.value = state.delay
        delayLabel.text = MPVQuickPlayerViewController.delayTitle(state.delay)
        delayStepper.accessibilityValue = delayLabel.text
        positionSlider.value = Float(control.position)
        positionSlider.accessibilityValue = String(Int(control.position.rounded()))
        positionLabel.text = mpvLocalized("subtitle.position.value", Int(control.position.rounded()))
        positionPresets.selectedSegmentIndex = control.position == 0 ? 0 : control.position == 100 ? 1 : UISegmentedControl.noSegment
        positionSlider.isEnabled = !usesOriginalASS
        positionPresets.isEnabled = !usesOriginalASS
        positionSlider.accessibilityHint = usesOriginalASS ? mpvLocalized("subtitle.original_ass.position_note") : nil
        originalSwitch.isOn = control.usesOriginalStyle
        automaticSwitch.isOn = control.automatic
        let languages: [MPVSubtitleLanguage] = [.simplifiedChinese, .traditionalChinese, .english]
        languageControl.selectedSegmentIndex = languages.firstIndex(of: control.language) ?? 0
        let baseNote = mpvLocalized(slot == .secondary ? "subtitle.secondary.note" : "subtitle.primary.note")
        note.text = usesOriginalASS
            ? mpvLocalized("subtitle.original_ass.position_note") + "\n" + baseNote : baseNote
    }

    @objc private func sourceTapped() { onSource?(sourceButton) }
    @objc private func delayChanged() {
        let delay = (delayStepper.value * 10).rounded() / 10
        delayLabel.text = MPVQuickPlayerViewController.delayTitle(delay)
        delayStepper.accessibilityValue = delayLabel.text
        onDelay?(delay)
    }
    @objc private func originalChanged() { onOriginalStyle?(originalSwitch.isOn) }
    @objc private func automaticChanged() { onAutomatic?(automaticSwitch.isOn) }
    @objc private func positionChanged() { onPosition?(Double(positionSlider.value.rounded())) }
    @objc private func positionPresetChanged() { onPosition?(positionPresets.selectedSegmentIndex == 0 ? 0 : 100) }
    @objc private func languageChanged() {
        let languages: [MPVSubtitleLanguage] = [.simplifiedChinese, .traditionalChinese, .english]
        guard languages.indices.contains(languageControl.selectedSegmentIndex) else { return }
        onLanguage?(languages[languageControl.selectedSegmentIndex])
    }
    @objc private func resetTapped() { onReset?() }
}
