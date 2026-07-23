import Foundation

extension MPVPlayerView {
    public var clientSubtitleRenderer: any MPVSubtitleRenderer {
        clientSubtitleController.renderer
    }

    public func useClientSubtitleRenderer(_ renderer: any MPVSubtitleRenderer) {
        clientSubtitleController.useRenderer(renderer)
    }

    public func selectClientSubtitle(_ document: MPVSubtitleDocument?) {
        clientSubtitleController.select(document)
        clientSubtitleController.update(at: currentTime, force: true)
        guard document != nil else { return }
        queue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            let snapshot = self.logicalSubtitleSelection()
            _ = self.performSubtitleSelectionTransaction(
                previous: snapshot,
                targetUsesOriginalStyle: snapshot.usesOriginalStyle,
                targetSubtitleID: snapshot.subtitleID,
                targetVisibility: false
            )
        }
    }

    public func clearClientSubtitle() {
        clientSubtitleController.clear()
    }

    @objc public func loadClientSubtitle(_ options: NSDictionary) {
        guard let requestID = options["requestID"] as? String,
              let urlString = options["url"] as? String,
              urlString.isEmpty == false else {
            return
        }
        // Kept as an Objective-C compatibility entry point. Playback always
        // delegates subtitle decoding and composition to libmpv.
        loadSubtitle([
            "requestID": requestID,
            "url": urlString,
            "usesOriginalStyle": options["usesOriginalStyle"] ?? NSNumber(value: false),
        ] as NSDictionary)
    }

    @objc public func cancelClientSubtitleLoad(_ options: NSDictionary) {
        cancelSubtitleLoad(options)
    }

    func updateClientSubtitle(at time: TimeInterval) {
        clientSubtitleController.update(at: time)
    }

    func applyClientSubtitleVisibility(_ visible: Bool) {
        clientSubtitleController.isVisible = visible
        clientSubtitleController.update(at: currentTime, force: true)
    }

    func applyClientSubtitleDelay(_ delay: TimeInterval) {
        clientSubtitleController.delay = delay
        clientSubtitleController.update(at: currentTime, force: true)
    }

    func applyClientSubtitleStyle(_ style: MPVSubtitleStyle) {
        clientSubtitleController.style = style
        clientSubtitleController.update(at: currentTime, force: true)
    }
}
