import Foundation
import QuartzCore
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#endif

extension MPVPlayerView {
    nonisolated func logEffectiveCacheSettings(reason: String) {
        let propertyNames = [
            MPVProperty.cache,
            MPVProperty.cacheSeconds,
            MPVProperty.demuxerCacheTime,
        ]
        let properties = propertyNames.map { name in
            "\(name)=\(getString(name) ?? "<unavailable>")"
        }.joined(separator: " ")
        mpvDebugLog(
            "cache settings effective reason=\(reason) configuredEnabled=\(cacheConfiguration.isEnabled) "
                + "configuredSeconds=\(cacheConfiguration.duration) "
                + "properties=[\(properties)]"
        )
    }

    /// Logs bounded cache counters periodically so a memory report can be
    /// correlated with mpv's forward queue and back buffer.
    nonisolated func logCacheRuntimeStateIfNeeded(currentTime: TimeInterval) {
        #if DEBUG
        guard cacheConfiguration.isEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastCacheDiagnosticsLogTime >= 10 else { return }
        lastCacheDiagnosticsLogTime = now

        var state = mpv_node()
        let stateStatus: Int32
        if let mpv {
            stateStatus = mpv_get_property(
                mpv,
                MPVProperty.demuxerCacheState,
                MPV_FORMAT_NODE,
                &state
            )
        } else {
            stateStatus = -1
        }

        var stateDescription = "status=\(stateStatus)"
        if stateStatus >= 0 {
            defer { mpv_free_node_contents(&state) }
            let forwardBytes = cacheNodeInt64(named: "fw-bytes", in: state)
            let cacheEnd = cacheNodeDouble(named: "cache-end", in: state)
            let rawRate = cacheNodeInt64(named: "raw-input-rate", in: state)
            stateDescription = "status=0 fwBytes=\(forwardBytes.map(String.init) ?? "unknown") "
                + "cacheEnd=\(cacheEnd.map { String(format: "%.3f", $0) } ?? "unknown") "
                + "rawInputRate=\(rawRate.map(String.init) ?? "unknown")"
        }

        mpvDebugLog(
            "cache runtime time=\(String(format: "%.3f", currentTime)) "
                + "cacheTime=\(getDoubleIfAvailable(MPVProperty.demuxerCacheTime).map { String(format: "%.3f", $0) } ?? "unknown") "
                + "cacheSpeed=\(getInt64("cache-speed").map(String.init) ?? "unknown") "
                + "\(stateDescription)"
        )
        #endif
    }

    private nonisolated func cacheNodeValue(named name: String, in node: mpv_node) -> mpv_node? {
        guard node.format == MPV_FORMAT_NODE_MAP,
              let list = node.u.list,
              let keys = list.pointee.keys,
              let values = list.pointee.values else { return nil }
        for index in 0 ..< Int(list.pointee.num) {
            guard let key = keys[index], String(cString: key) == name else { continue }
            return values[index]
        }
        return nil
    }

    private nonisolated func cacheNodeInt64(named name: String, in node: mpv_node) -> Int64? {
        guard let value = cacheNodeValue(named: name, in: node) else { return nil }
        switch value.format {
        case MPV_FORMAT_INT64:
            return value.u.int64
        case MPV_FORMAT_DOUBLE:
            return Int64(value.u.double_)
        default:
            return nil
        }
    }

    private nonisolated func cacheNodeDouble(named name: String, in node: mpv_node) -> Double? {
        guard let value = cacheNodeValue(named: name, in: node) else { return nil }
        switch value.format {
        case MPV_FORMAT_DOUBLE:
            return value.u.double_
        case MPV_FORMAT_INT64:
            return Double(value.u.int64)
        default:
            return nil
        }
    }
}
