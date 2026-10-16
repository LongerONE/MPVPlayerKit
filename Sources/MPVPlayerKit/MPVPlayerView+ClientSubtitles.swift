import Foundation

extension MPVPlayerView {
    public var clientSubtitleRenderer: any MPVSubtitleRenderer {
        clientSubtitleController.renderer
    }

    public func useClientSubtitleRenderer(_ renderer: any MPVSubtitleRenderer) {
        clientSubtitleController.useRenderer(renderer)
        if decodedSubtitleText != nil { renderDecodedSubtitleText() }
    }

    /// 选择宿主自备的客户端字幕文档进行自定义 UI 渲染。
    /// 会把当前原生/libmpv 字幕轨设为不可见，避免双重绘制。
    public func selectClientSubtitle(_ document: MPVSubtitleDocument?) {
        clientSubtitleController.select(document)
        clientSubtitleController.update(at: currentTime, force: true)
        currentSubtitleFontCapability = document == nil ? .noSubtitle : .supported
        guard document != nil else { return }
        queue.async { [weak self] in
            guard let self, self.mpv != nil else { return }
            self.subtitleSlots.selectionRevision[.primary, default: 0] &+= 1
            self.subtitleSlots.publishRevision(self.subtitleSlots.selectionRevision[.primary, default: 0], slot: .primary)
            _ = self.beginNewSubtitleSelection(reason: "client-selection")
            let snapshot = self.logicalSubtitleSelection()
            _ = self.performSubtitleSelectionTransaction(
                previous: snapshot,
                targetUsesOriginalStyle: snapshot.usesOriginalStyle,
                targetSubtitleID: nil,
                targetVisibility: false
            )
        }
    }

    public func clearClientSubtitle() {
        decodedSubtitleText = nil
        clientSubtitleController.clear()
    }

    /// 兼容入口：加载外挂字幕并由 **libmpv** 渲染（与 `loadSubtitle` 相同路径）。
    /// 若需客户端自绘，请改用 `selectClientSubtitle(document:)`。
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

    /// 同时取消 client/libmpv 两条路径上以该 requestID 挂起的加载。
    @objc public func cancelClientSubtitleLoad(_ options: NSDictionary) {
        cancelSubtitleLoad(options)
    }

    func beginExternalSubtitleDownload() {
        clearClientSubtitle()
        queue.async { [weak self] in
            _ = self?.beginNewSubtitleSelection(reason: "subtitle-download")
        }
    }

    func updateClientSubtitle(at time: TimeInterval) {
        renderSecondarySubtitleText()
        if decodedSubtitleText != nil {
            renderDecodedSubtitleText()
        } else {
            clientSubtitleController.update(at: time)
        }
    }

    func renderDecodedSubtitleText() {
        guard !clientSubtitleController.hasSelection else { return }
        let text = decodedSubtitleText ?? ""
        clientSubtitleController.renderer.render(MPVSubtitlePresentation(
            cues: text.isEmpty ? [] : [MPVSubtitleCue(startTime: 0, endTime: .greatestFiniteMagnitude, text: text)],
            style: clientSubtitleController.style
        ))
    }

    nonisolated static func supportsDecodedSubtitleText(codec: String?, usesOriginalStyle: Bool) -> Bool {
        guard !usesOriginalStyle, let codec = codec?.lowercased() else { return false }
        return ["subrip", "srt", "webvtt", "vtt", "text", "mov_text"].contains(codec) || isASSSubtitleCodec(codec)
    }

    nonisolated func shouldRenderDecodedSubtitleText(id: Int64?, usesOriginalStyle: Bool) -> Bool {
        guard let id else { return false }
        let count = Int(getInt64("track-list/count") ?? 0)
        for index in 0..<count where getInt64("track-list/\(index)/id") == id
            && getString("track-list/\(index)/type") == "sub" {
            return Self.supportsDecodedSubtitleText(
                codec: getString("track-list/\(index)/codec"), usesOriginalStyle: usesOriginalStyle
            )
        }
        return false
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
        renderSecondarySubtitleText()
        clientSubtitleController.update(at: currentTime, force: true)
        if decodedSubtitleText != nil { renderDecodedSubtitleText() }
    }
}
