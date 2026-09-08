import UIKit
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#endif

/// 仅在 MPV 队列访问，生命周期与一次 configure 对应，而不是与降级 profile 对应。
final class MPVDiagnosticProbe {
    static let cachedMPVPropertyNames = [
        "mpv-version", "ffmpeg-version", "libass-version",
        "vo", "gpu-api", "gpu-context",
    ]

    let channel: MPVDiagnosticChannel
    var process = MPVDiagnosticProcessSampler()
    var decoderDrops = MPVDiagnosticCounter()
    var outputDrops = MPVDiagnosticCounter()
    var reportedFirstFrame = false
    private var staticMPVFieldCache: [String: String] = [:]
    private var staticMPVFieldCacheHandle: OpaquePointer?

    init(channel: MPVDiagnosticChannel) { self.channel = channel }

    func bindStaticMPVFieldCache(to handle: OpaquePointer) {
        guard staticMPVFieldCacheHandle != handle else { return }
        staticMPVFieldCacheHandle = handle
        staticMPVFieldCache.removeAll(keepingCapacity: true)
    }

    func clearStaticMPVFieldCache() {
        staticMPVFieldCacheHandle = nil
        staticMPVFieldCache.removeAll(keepingCapacity: true)
    }

    func staticMPVField(
        _ property: String,
        handle: OpaquePointer,
        load: () -> String?
    ) -> String? {
        bindStaticMPVFieldCache(to: handle)
        if let value = staticMPVFieldCache[property] { return value }
        guard let value = load() else { return nil }
        staticMPVFieldCache[property] = value
        return value
    }
}

extension MPVPlayerView {
    func configurePowerDiagnostics(_ configuration: NSDictionary) {
        diagnosticMonitor?.stop()
        diagnosticMonitor = nil
        queue.async { [weak self] in self?.finishPowerDiagnostics(reason: "重新配置") }
        let enabled = (configuration["diagnosticsEnabled"] as? NSNumber)?.boolValue
            ?? MPVDiagnostics.isEnabledByDefault
        guard enabled else {
            diagnosticSessionID = nil
            queue.async { [weak self] in self?.diagnosticProbe = nil }
            return
        }
        let source = MPVDiagnosticSource(rawValue: configuration["diagnosticSource"] as? String ?? "") ?? .automatic
        let host = MPVDiagnosticHost(rawValue: configuration["diagnosticHost"] as? String ?? "") ?? .unspecified
        let channel = MPVDiagnosticChannel()
        diagnosticSessionID = channel.sessionID
        let monitor = MPVDiagnosticMonitor(playerView: self, channel: channel)
        diagnosticMonitor = monitor
        queue.async { [weak self] in self?.diagnosticProbe = MPVDiagnosticProbe(channel: channel) }
        monitor.start(source: MPVDiagnosticSource.resolve(source, url: url), host: host)
    }

    @objc public func diagnosticLogFiles() async throws -> [URL] {
        guard let diagnosticSessionID else { return [] }
        return try await MPVDiagnostics.logFiles(sessionID: diagnosticSessionID)
    }

    /// 主线程只采集 UIKit 属性；mpv 属性读取始终在原有串行队列执行。
    func requestDiagnosticSnapshot(_ event: String, fields: [String: String] = [:]) {
        guard let monitor = diagnosticMonitor else { return }
        if event == "周期快照" {
            guard !monitor.periodicSnapshotPending else { return }
            monitor.periodicSnapshotPending = true
        }
        var values = monitor.systemFields()
        values.merge(fields) { _, new in new }
        let snapshot = values
        let sessionID = monitor.channel.sessionID
        queue.async { [weak self] in
            guard let self, self.diagnosticProbe?.channel.sessionID == sessionID else { return }
            self.recordDiagnosticSnapshot(event, fields: snapshot)
            if event == "周期快照" {
                self.notifyOnMain {
                    guard self.diagnosticMonitor?.channel.sessionID == sessionID else { return }
                    self.diagnosticMonitor?.periodicSnapshotPending = false
                }
            }
        }
    }

    nonisolated func recordDiagnosticEvent(_ event: String, fields: [String: String] = [:]) {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            diagnosticProbe?.channel.record(event, fields: fields)
        } else {
            queue.async { [weak self] in self?.diagnosticProbe?.channel.record(event, fields: fields) }
        }
    }

    nonisolated func recordDiagnosticSnapshot(_ event: String, fields: [String: String] = [:], finish: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let probe = diagnosticProbe else { return }
        let sampleStarted = ProcessInfo.processInfo.systemUptime
        var values = fields
        values["解码配置"] = activeProfileDescription
        values["请求画质"] = String(describing: videoQualityPreset)
        values["请求去色带"] = String(debandEnabled)
        values["实际去色带策略"] = String(effectiveDebandEnabled)
        // 只读取固定白名单；不读取 path、filename、metadata、track title、headers 或 sub-text。
        let properties = [
            "video-codec", "video-format", "video-params/w", "video-params/h",
            "video-params/pixelformat", "video-params/hw-pixelformat",
            "video-params/colormatrix", "video-params/primaries", "video-params/gamma",
            "video-params/colorlevels", "video-params/sig-peak",
            "video-params/bit-depth", "video-params/codec-profile",
            "video-params/dolby-vision-profile", "video-params/light", "video-params/average-bpp",
            "video-out-params/primaries", "video-out-params/gamma",
            "container-fps", "estimated-vf-fps", "estimated-display-fps", "video-bitrate", "audio-codec",
            "hwdec", "hwdec-current", "vd-lavc-dr",
            "fbo-format", "target-trc", "target-prim", "target-colorspace-hint",
            "scale", "cscale", "dscale", "correct-downscaling", "linear-downscaling",
            "sigmoid-upscaling", "dither", "dither-depth", "deband", "hdr-compute-peak",
            "allow-delayed-peak-detect", "interpolation", "video-sync", "blend-subtitles",
            "sid", "sub-visibility", "sub-ass-override", "speed", "pause", "time-pos", "duration",
            "paused-for-cache", "cache-buffering-state", "cache", "cache-secs",
            "demuxer-cache-duration", "demuxer-cache-time", "demuxer-cache-state/fw-bytes",
            "demuxer-cache-state/total-bytes", "cache-speed", "demuxer-max-bytes",
            "decoder-frame-drop-count", "frame-drop-count", "mistimed-frame-count",
            "vo-delayed-frame-count", "avsync",
        ]
        if let mpv {
            for property in MPVDiagnosticProbe.cachedMPVPropertyNames {
                values[property] = probe.staticMPVField(property, handle: mpv) {
                    getString(property).map { String($0.prefix(160)) }
                } ?? "不可用"
            }
        } else {
            for property in MPVDiagnosticProbe.cachedMPVPropertyNames {
                values[property] = "不可用"
            }
        }
        for property in properties {
            // 防止意外超长属性放大日志负担；不可用不伪装成数值零。
            values[property] = getString(property).map { String($0.prefix(160)) } ?? "不可用"
        }
        if let count = getInt64("track-list/count"), count > 0 {
            for index in 0..<min(count, 64) {
                let prefix = "track-list/\(index)"
                guard getFlag("\(prefix)/selected") == true,
                      let type = getString("\(prefix)/type"), ["video", "audio", "sub"].contains(type) else { continue }
                for name in ["codec", "codec-profile", "demux-w", "demux-h", "demux-fps", "demux-bitrate"] {
                    values["当前\(type)轨道/\(name)"] = getString("\(prefix)/\(name)").map { String($0.prefix(160)) } ?? "不可用"
                }
            }
        }
        values["解码丢帧增量"] = probe.decoderDrops.update(getInt64("decoder-frame-drop-count"))
        values["输出丢帧增量"] = probe.outputDrops.update(getInt64("frame-drop-count"))
        values.merge(probe.process.sample()) { _, new in new }
        values["采集耗时毫秒"] = String(format: "%.3f", (ProcessInfo.processInfo.systemUptime - sampleStarted) * 1_000)
        probe.channel.record(event, fields: values, finish: finish)
        if finish { diagnosticProbe = nil }
    }

    nonisolated func recordDiagnosticMPVEvent(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let probe = diagnosticProbe else { return }
        switch event.pointee.event_id {
        case MPV_EVENT_FILE_LOADED:
            recordDiagnosticSnapshot("媒体加载完成")
        case MPV_EVENT_PLAYBACK_RESTART:
            let name = probe.reportedFirstFrame ? "播放恢复就绪" : "首帧就绪近似值"
            probe.reportedFirstFrame = true
            recordDiagnosticSnapshot(name, fields: ["时间口径": "MPV_PLAYBACK_RESTART，非屏幕实际呈现时间"])
        case MPV_EVENT_VIDEO_RECONFIG:
            recordDiagnosticSnapshot("视频参数变化")
        case MPV_EVENT_END_FILE:
            let end = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            recordDiagnosticSnapshot("媒体结束", fields: [
                "结束原因码": end.map { String($0.reason.rawValue) } ?? "不可用",
                "错误码": end.map { String($0.error) } ?? "不可用",
            ])
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.pointee.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let name = property.name else { return }
            let key = String(cString: name)
            if ["pause", "paused-for-cache", "seeking", "hwdec-current"].contains(key) {
                recordDiagnosticEvent("播放属性变化", fields: ["属性": key, "值": getString(key) ?? "不可用"])
            }
        default:
            break
        }
    }

    nonisolated func finishPowerDiagnostics(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let sessionID = diagnosticProbe?.channel.sessionID else { return }
        recordDiagnosticSnapshot("会话汇总", fields: ["结束原因": reason], finish: true)
        notifyOnMain {
            guard self.diagnosticMonitor?.channel.sessionID == sessionID else { return }
            self.diagnosticMonitor?.stop()
            self.diagnosticMonitor = nil
        }
    }
}
