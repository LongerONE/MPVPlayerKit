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
              let url = URL(string: urlString) else {
            notifyClientSubtitleLoad(requestID: options["requestID"] as? String ?? "", success: false)
            return
        }
        clientSubtitleLoadTasks[requestID]?.cancel()
        let headers = options["headers"] as? [String: String] ?? [:]
        clientSubtitleLoadTasks[requestID] = Task { [weak self] in
            do {
                let document = try await MPVSubtitleDocument.load(from: url, headers: headers)
                try Task.checkCancellation()
                guard let self else { return }
                selectClientSubtitle(document)
                clientSubtitleController.isVisible = true
                notifyClientSubtitleLoad(requestID: requestID, success: true)
            } catch {
                guard Task.isCancelled == false, let self else { return }
                notifyClientSubtitleLoad(requestID: requestID, success: false)
            }
            self?.clientSubtitleLoadTasks[requestID] = nil
        }
    }

    @objc public func cancelClientSubtitleLoad(_ options: NSDictionary) {
        guard let requestID = options["requestID"] as? String else { return }
        clientSubtitleLoadTasks.removeValue(forKey: requestID)?.cancel()
        notifyClientSubtitleLoad(requestID: requestID, success: false)
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

    private func notifyClientSubtitleLoad(requestID: String, success: Bool) {
        NotificationCenter.default.post(
            name: MPVPlayerKitNotification.didLoadSubtitle,
            object: self,
            userInfo: [
                MPVPlayerKitNotificationKey.requestID: requestID,
                MPVPlayerKitNotificationKey.success: success,
            ]
        )
    }
}
