import UIKit

@MainActor
final class MPVQuickPlayerSubtitleControlView: MPVQuickPlayerSettingsPanelView {
    let sourceButton = UIButton(type: .system)
    private let delayStepper = UIStepper()
    private let delayLabel = UILabel()
    private let layoutControl = UISegmentedControl(items: [mpvLocalized("subtitle.layout.independent"), mpvLocalized("subtitle.layout.stacked")])
    private var layoutRow: UIView?
    var refreshProvider: (() -> Void)?
    var layoutStatusProvider: (() -> MPVSubtitleLayoutStatus?)?
    var onLayoutMode: ((MPVSubtitleLayoutMode) -> Void)?
    private var layoutTask: Task<Void, Never>?
    private var currentSlot = MPVSubtitleSlot.primary
    private var currentPosition: Double = 100
    private var currentOriginalASS = false
    private let positionSlider = UISlider()
    private let positionLabel = UILabel()
    private let positionPresets = UISegmentedControl(items: [
        mpvLocalized("subtitle.position.top"), mpvLocalized("subtitle.position.bottom"),
    ])
    private let originalSwitch = UISwitch()
    private var originalStyleRow: UIView?
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
        layoutControl.accessibilityIdentifier = "MPVQuickPlayer.subtitleLayoutMode"
        layoutControl.addTarget(self, action: #selector(layoutChanged), for: .valueChanged)
        let layoutRow = makeSegmentRow(title: mpvLocalized("subtitle.layout.title"), segmentedControl: layoutControl)
        self.layoutRow = layoutRow
        contentStack.addArrangedSubview(layoutRow)
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
        positionLabel.numberOfLines = 0
        let positionRow = UIStackView(arrangedSubviews: [positionLabel, positionSlider, positionPresets])
        positionRow.axis = .vertical
        positionRow.spacing = 6
        positionPresets.addTarget(self, action: #selector(positionPresetChanged), for: .valueChanged)
        contentStack.addArrangedSubview(positionRow)
        originalSwitch.addTarget(self, action: #selector(originalChanged), for: .valueChanged)
        originalSwitch.accessibilityIdentifier = "MPVQuickPlayer.subtitleASSMode"
        let originalStyleRow = makeSwitchRow(title: mpvLocalized("subtitle.original_ass"), switchView: originalSwitch)
        self.originalStyleRow = originalStyleRow
        contentStack.addArrangedSubview(originalStyleRow)
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
        currentSlot = slot
        currentPosition = control.position
        currentOriginalASS = usesOriginalASS
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
        originalStyleRow?.isHidden = !state.supportsASSMode
        automaticSwitch.isOn = control.automatic
        let languages: [MPVSubtitleLanguage] = [.simplifiedChinese, .traditionalChinese, .english]
        languageControl.selectedSegmentIndex = languages.firstIndex(of: control.language) ?? 0
        refreshLayoutControls()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        layoutTask?.cancel()
        layoutTask = nil
        guard window != nil, layoutStatusProvider != nil else { return }
        refreshLayoutControls()
        layoutTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard let self, self.window != nil else { return }
                if let refresh = self.refreshProvider { refresh() }
                else { self.refreshLayoutControls() }
            }
        }
    }

    private func refreshLayoutControls() {
        let status = layoutStatusProvider?() ?? .init(requestedMode: .independent)
        layoutRow?.isHidden = currentSlot != .secondary
        layoutControl.selectedSegmentIndex = status.requestedMode.rawValue
        let follows = status.effectiveMode == .stacked
        let blocked = currentOriginalASS || (currentSlot == .secondary && follows)
        positionSlider.isEnabled = !blocked
        positionPresets.isEnabled = !blocked
        let hint = follows ? mpvLocalized("subtitle.layout.position_note")
            : currentOriginalASS ? mpvLocalized("subtitle.original_ass.position_note") : nil
        positionSlider.accessibilityHint = hint
        positionLabel.text = follows && currentSlot == .secondary ? mpvLocalized("subtitle.layout.position_note")
            : follows ? mpvLocalized("subtitle.layout.group_position") + "：\(Int(currentPosition.rounded()))"
            : mpvLocalized("subtitle.position.value", Int(currentPosition.rounded()))
        var notes = [mpvLocalized(currentSlot == .secondary ? "subtitle.secondary.note" : "subtitle.primary.note")]
        if currentOriginalASS { notes.insert(mpvLocalized("subtitle.original_ass.position_note"), at: 0) }
        if let reason = status.fallbackReason { notes.insert(mpvLocalized(reason.localizationKey), at: 0) }
        else if follows { notes.insert(mpvLocalized("subtitle.layout.position_note"), at: 0) }
        note.text = notes.joined(separator: "\n")
        note.accessibilityIdentifier = "MPVQuickPlayer.subtitleLayoutNote"
    }

    @objc private func layoutChanged() {
        guard let mode = MPVSubtitleLayoutMode(rawValue: layoutControl.selectedSegmentIndex) else { return }
        onLayoutMode?(mode)
        refreshLayoutControls()
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
