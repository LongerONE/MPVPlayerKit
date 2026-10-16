import UIKit
import UniformTypeIdentifiers

extension MPVQuickPlayerViewController {
    func showSubtitleSettings() {
        let options: [MPVQuickPlayerActionSheetOption] = [
            .init(title: mpvLocalized("subtitle.primary")) { [weak self] in
                self?.presentAfterCurrentSheet { $0.showSubtitleControl(in: .primary) }
            },
            .init(title: mpvLocalized("subtitle.secondary")) { [weak self] in
                self?.presentAfterCurrentSheet { $0.showSubtitleControl(in: .secondary) }
            },
            .init(title: mpvLocalized("subtitle.shared_style")) { [weak self] in
                self?.presentAfterCurrentSheet { $0.showSharedSubtitleStyle() }
            },
        ]
        presentActionSheet(title: mpvLocalized("settings.subtitle"), sourceView: subtitleButton,
                           options: options, cancelTitle: mpvLocalized("common.cancel"))
    }

    func applySubtitlePreferences() {
        for slot in [MPVSubtitleSlot.primary, .secondary] {
            guard let control = subtitleControls[slot] else { continue }
            player.setSubtitlePosition(control.position, in: slot)
            player.setSubtitleUsesOriginalStyle(control.usesOriginalStyle, in: slot)
        }
    }

    func showSubtitleControl(in slot: MPVSubtitleSlot) {
        subtitlePanelSlot = slot
        let panel = MPVQuickPlayerSubtitleControlView()
        let refresh = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.refreshSubtitleControl(panel, in: slot)
        }
        panel.onSource = { [weak self] view in self?.showSubtitleSource(in: slot, from: view) }
        panel.onDelay = { [weak self] delay in
            self?.setSubtitleDelay(delay, in: slot)
        }
        panel.onPosition = { [weak self] position in
            self?.updateSubtitleControl(in: slot) { $0.position = position }
            refresh()
        }
        panel.onOriginalStyle = { [weak self] original in
            self?.updateSubtitleControl(in: slot) { $0.usesOriginalStyle = original }
            refresh()
        }
        panel.onAutomatic = { [weak self] enabled in
            self?.updateSubtitleControl(in: slot) { $0.automatic = enabled }
            self?.restartAutomaticSubtitleChoice(in: slot)
            self?.automaticallySelectSubtitles()
            refresh()
        }
        panel.onLanguage = { [weak self] language in
            self?.updateSubtitleControl(in: slot) { $0.language = language }
            self?.restartAutomaticSubtitleChoice(in: slot)
            self?.automaticallySelectSubtitles()
            refresh()
        }
        panel.onReset = { [weak self] in
            self?.updateSubtitleControl(in: slot) {
                $0 = .init(position: slot == .primary ? 100 : 0)
            }
            refresh()
        }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self, self.settingsPanelOverlay === panel else { return }
            self.settingsPanelOverlay = nil
        }
        refresh()
        presentSettingsPanel(panel)
    }

    func refreshActiveSubtitleControl() {
        if let panel = settingsPanelOverlay as? MPVQuickPlayerSubtitleControlView {
            refreshSubtitleControl(panel, in: subtitlePanelSlot)
        }
    }

    func refreshSubtitleControl(_ panel: MPVQuickPlayerSubtitleControlView, in slot: MPVSubtitleSlot) {
        guard let control = subtitleControls[slot] else { return }
        let state = player.subtitleState(in: slot)
        let track = player.tracks(ofType: .subtitle).first { Int64($0.id) == state.trackID }
        let source = track?.name ?? (state.sourceID == nil ? mpvLocalized("common.off") : mpvLocalized("subtitle.external"))
        let codec = track?.codec.lowercased()
        let usesOriginalASS = control.usesOriginalStyle && (codec == "ass" || codec == "ssa" || codec == "substation_alpha")
        panel.update(slot: slot, state: state, control: control, source: source, usesOriginalASS: usesOriginalASS)
    }

    func updateSubtitleControl(in slot: MPVSubtitleSlot,
                               _ update: (inout MPVQuickPlayerSubtitlePreferences.Control) -> Void) {
        var control = subtitleControls[slot] ?? .init(position: slot == .primary ? 100 : 0)
        update(&control)
        subtitleControls[slot] = control
        MPVQuickPlayerSubtitlePreferences.save(control, in: slot)
        player.setSubtitlePosition(control.position, in: slot)
        player.setSubtitleUsesOriginalStyle(control.usesOriginalStyle, in: slot)
    }

    func showSharedSubtitleStyle() {
        let panel = MPVQuickPlayerSubtitleSettingsView()
        panel.shadowRadiusAvailabilityProvider = { [weak self] in
            let capabilities = Dictionary(uniqueKeysWithValues: MPVSubtitleSlot.allCases.map { slot in
                (slot, self?.player.subtitleState(in: slot).shadowRadiusCapability ?? .inactive)
            })
            return MPVSubtitleShadowRadiusAvailability(capabilities: capabilities)
        }
        panel.refreshShadowRadiusAvailability()
        panel.onStyleChange = { [weak self] in self?.setSubtitleStyle($0) }
        panel.onFontTap = { [weak self] view in self?.showSubtitleFontPicker(from: view) }
        panel.onDetailsTap = { [weak self] in
            self?.presentMessage(title: mpvLocalized("subtitle.shared_style"),
                                 message: mpvLocalized("subtitle.shared_style.note"))
        }
        panel.onDismiss = { [weak self, weak panel] in
            guard let self, self.settingsPanelOverlay === panel else { return }
            self.settingsPanelOverlay = nil
        }
        panel.update(style: subtitleStyle, delay: subtitleDelay)
        presentSettingsPanel(panel)
    }

    public func setSubtitleStyle(_ style: MPVSubtitleStyle) {
        subtitleStyle = style
        MPVQuickPlayerSubtitlePreferences.save(style)
        applySubtitleStyle()
    }

    func applySubtitleStyle() {
        var style = subtitleStyle
        // Per-slot positions own placement; retain the legacy margin in saved preferences.
        style.bottomOffset = 0
        player.updateSubtitleStyle(style)
    }

    public func setSubtitleDelay(_ delay: TimeInterval) {
        setSubtitleDelay(delay, in: .primary)
    }

    public func setSubtitleDelay(_ delay: TimeInterval, in slot: MPVSubtitleSlot) {
        guard delay.isFinite else { return }
        let value = min(60, max(-60, delay))
        if slot == .primary { subtitleDelay = value }
        player.setSubtitleDelay(value, in: slot)
    }

    func showSubtitleSource(in slot: MPVSubtitleSlot, from sourceView: UIView) {
        let state = player.subtitleState(in: slot)
        let other = player.subtitleState(in: slot == .primary ? .secondary : .primary)
        var options: [MPVQuickPlayerActionSheetOption] = [
            .init(title: mpvLocalized("common.off"), isSelected: state.sourceID == nil && state.trackID == nil) { [weak self] in
                self?.subtitleManualSlots.insert(slot)
                self?.cancelExternalSubtitleLoad(in: slot)
                self?.player.clearSubtitle(in: slot)
                self?.refreshActiveSubtitleControl()
            },
            .init(title: mpvLocalized("subtitle.load_external")) { [weak self] in
                self?.presentAfterCurrentSheet { $0.presentExternalSubtitlePicker(in: slot) }
            },
        ]
        options += player.tracks(ofType: .subtitle).map { track in
            let occupied = Int64(track.id) == other.trackID
            return .init(title: occupied ? mpvLocalized("subtitle.occupied.track", track.name) : track.name,
                         isSelected: Int64(track.id) == state.trackID) { [weak self] in
                guard let self else { return }
                guard !occupied else {
                    self.presentMessage(title: mpvLocalized("subtitle.error.title"), message: mpvLocalized("subtitle.occupied"))
                    return
                }
                self.subtitleManualSlots.insert(slot)
                if self.player.select(track: track, in: slot) {
                    self.applySubtitlePreferences()
                    self.player.setSubtitlesVisible(true, in: slot)
                }
                self.refreshActiveSubtitleControl()
            }
        }
        presentActionSheet(title: mpvLocalized(slot == .primary ? "subtitle.primary" : "subtitle.secondary"),
                           sourceView: sourceView, options: options, cancelTitle: mpvLocalized("common.cancel"))
    }

    func presentExternalSubtitlePicker(in slot: MPVSubtitleSlot = .primary) {
        subtitleImportSlot = slot
        subtitleImportIsFont = false
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.text, .data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presentInPlayerOrientation(picker)
    }

    func loadExternalSubtitle(from url: URL, usesOriginalStyle: Bool) {
        loadExternalSubtitle(from: url, in: subtitleImportSlot, usesOriginalStyle: usesOriginalStyle)
    }

    func loadExternalSubtitle(from url: URL, in slot: MPVSubtitleSlot, usesOriginalStyle: Bool) {
        subtitleManualSlots.insert(slot)
        cancelExternalSubtitleLoad(in: slot)
        let generation = (subtitleLoadGeneration[slot] ?? 0) &+ 1
        subtitleLoadGeneration[slot] = generation
        loadingIndicator.startAnimating()
        statusLabel.text = mpvLocalized("subtitle.loading")
        subtitleRequests[slot] = player.loadExternalSubtitle(from: url, in: slot, usesOriginalStyle: usesOriginalStyle) {
            [weak self] success in
            guard let self, self.subtitleLoadGeneration[slot] == generation else { return }
            self.subtitleRequests[slot] = nil
            if Self.shouldShowLoading(for: self.playbackState) || !self.subtitleRequests.isEmpty {
                self.loadingIndicator.startAnimating()
            } else { self.loadingIndicator.stopAnimating() }
            self.updateStatusLabel()
            if success {
                self.updateSubtitleControl(in: slot) { $0.usesOriginalStyle = usesOriginalStyle }
                self.player.setSubtitlesVisible(true, in: slot)
                self.refreshActiveSubtitleControl()
            } else {
                self.presentMessage(title: mpvLocalized("subtitle.error.title"),
                                    message: mpvLocalized(slot == .primary ? "subtitle.error.primary" : "subtitle.error.secondary"))
            }
        }
    }

    func cancelExternalSubtitleLoad(in slot: MPVSubtitleSlot = .primary) {
        subtitleLoadGeneration[slot] = (subtitleLoadGeneration[slot] ?? 0) &+ 1
        guard let request = subtitleRequests.removeValue(forKey: slot) else { return }
        player.cancelExternalSubtitleLoad(request)
        if !Self.shouldShowLoading(for: playbackState), subtitleRequests.isEmpty { loadingIndicator.stopAnimating() }
        updateStatusLabel()
    }

    func showSubtitleFontPicker(from sourceView: UIView) {
        presentActionSheet(title: mpvLocalized("subtitle.font"), message: mpvLocalized("subtitle.shared_style.note"), sourceView: sourceView,
                          options: [
                            .init(title: mpvLocalized("subtitle.font.import")) { [weak self] in
                                self?.presentAfterCurrentSheet { controller in
                                    controller.subtitleImportIsFont = true
                                    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
                                    picker.delegate = controller
                                    controller.presentInPlayerOrientation(picker)
                                }
                            },
                            .init(title: mpvLocalized("subtitle.font.reset")) { [weak self] in self?.resetSubtitleFont() },
                          ], cancelTitle: mpvLocalized("common.cancel"))
    }
}
