import Foundation
import QuartzCore
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#endif

extension MPVPlayerView {
    /// Removes only the persistent byte-range cache for the configured video.
    @objc public func clearPersistentVideoCache() -> Bool {
        guard let sourceURL = url, sourceURL.isFileURL == false else {
            mpvDebugLog("persistent cache clear skipped missing remote source")
            return false
        }

        persistentCacheContext?.setPersistenceEnabled(false)
        let cacheKey = persistentCacheContext?.cacheKey
            ?? MPVPersistentVideoCacheContext.makeCacheKey(
                sourceURL: sourceURL,
                headers: headers,
                userAgent: userAgent
            )
        let directoryURL = persistentCacheContext?.cacheDirectoryURL ?? Self.videoCacheDirectoryURL
        let entryURL = directoryURL.appendingPathComponent(cacheKey, isDirectory: true)
        do {
            try FileManager.default.removeItem(at: entryURL)
            mpvDebugLog("persistent cache cleared key=\(cacheKey)")
            return true
        } catch CocoaError.fileNoSuchFile {
            mpvDebugLog("persistent cache clear skipped entry-missing key=\(cacheKey)")
            return true
        } catch {
            mpvDebugLog(
                "persistent cache clear failed key=\(cacheKey) error=\(error.localizedDescription)"
            )
            return false
        }
    }

    nonisolated func logEffectiveCacheSettings(reason: String) {
        let propertyNames = [
            MPVProperty.cache,
            MPVProperty.cacheSeconds,
            MPVProperty.cacheOnDisk,
            MPVProperty.demuxerCacheDirectory,
            MPVProperty.demuxerCacheTime,
        ]
        let properties = propertyNames.map { name in
            "\(name)=\(getString(name) ?? "<unavailable>")"
        }.joined(separator: " ")
        mpvDebugLog(
            "cache settings effective reason=\(reason) configuredEnabled=\(cacheConfiguration.isEnabled) "
                + "configuredSeconds=\(cacheConfiguration.duration) configuredOnDisk=\(cacheConfiguration.isDiskCacheEnabled) "
                + "properties=[\(properties)] persistentContext=\(persistentCacheContext != nil) "
                + "directory=\(Self.videoCacheDirectoryURL.path)"
        )
    }

    /// Logs bounded cache counters periodically so a memory report can be
    /// correlated with mpv's forward queue, back buffer and file cache.
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
            let fileBytes = cacheNodeInt64(named: "file-cache-bytes", in: state)
            let cacheEnd = cacheNodeDouble(named: "cache-end", in: state)
            let rawRate = cacheNodeInt64(named: "raw-input-rate", in: state)
            stateDescription = "status=0 fwBytes=\(forwardBytes.map(String.init) ?? "unknown") "
                + "fileCacheBytes=\(fileBytes.map(String.init) ?? "unknown") "
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
