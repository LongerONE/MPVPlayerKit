import Foundation

#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#endif

extension MPVPlayerView {
    /// Safari UA: some CDNs reject `Lavf/*` or bare player agents.
    nonisolated static let defaultNetworkUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    nonisolated var isNetworkURL: Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Master `.m3u8` playlists pull many AUTOSELECT renditions; treat all HLS as sensitive.
    nonisolated var isHLSStreamURL: Bool {
        guard let url else { return false }
        let text = url.absoluteString.lowercased()
        return url.pathExtension.lowercased() == "m3u8"
            || text.contains(".m3u8")
            || text.contains("m3u8?")
    }

    /// Options applied before `mpv_initialize` for HTTP(S) / HLS.
    ///
    /// Apple-style multi-rendition masters (adv_dv_atmos) otherwise stall the
    /// lavf HLS demuxer: it fans out many parallel variant/audio/subtitle
    /// opens, and a short analyzeduration treats the still-loading master as
    /// invalid input.
    nonisolated var networkSetupOptions: [(String, String)] {
        var options: [(String, String)] = []
        if isNetworkURL {
            options.append(("network-timeout", "15"))
            // Serialize HLS segment fetches and fail fast instead of hanging
            // behind a proxy/connection storm.
            options.append((
                "stream-lavf-o",
                "timeout=15000000,reconnect=1,reconnect_streamed=1,reconnect_delay_max=2"
            ))
        }
        if isHLSStreamURL {
            options.append((
                "demuxer-lavf-o",
                "probesize=5242880,analyzeduration=10000000,"
                    + "extension_picky=0,http_multiple=0,max_reload=20,seg_max_retry=2,"
                    + "allowed_extensions=ALL"
            ))
            // Prefer a mid ladder tier so the demuxer does not keep the 4K
            // HEVC + Atmos combinations selected by default.
            options.append(("hls-bitrate", "5000000"))
        }
        return options
    }

    nonisolated func applyNetworkSetupOptions() {
        let effectiveUserAgent: String
        if let userAgent, userAgent.isEmpty == false {
            effectiveUserAgent = userAgent
        } else if isNetworkURL {
            effectiveUserAgent = Self.defaultNetworkUserAgent
        } else {
            effectiveUserAgent = ""
        }
        if effectiveUserAgent.isEmpty == false {
            checkError(
                mpv_set_option_string(mpv, "user-agent", effectiveUserAgent),
                operation: "set_option user-agent",
                notifyOnFailure: false
            )
        }

        let httpHeaders = makeMPVHTTPHeaderFields()
        mpvDebugLog(
            "setupMPV http headers total=\(headers.count) "
                + "forwarded=\(httpHeaders.fields.count) "
                + "skippedAuthHeaders=\(httpHeaders.skippedAuthHeaders) "
                + "isHLS=\(isHLSStreamURL)"
        )
        if httpHeaders.fields.isEmpty == false {
            checkError(
                mpv_set_option_string(
                    mpv,
                    "http-header-fields",
                    httpHeaders.fields.joined(separator: ",")
                ),
                operation: "set_option http-header-fields",
                notifyOnFailure: false
            )
        }

        for option in networkSetupOptions {
            let status = mpv_set_option_string(mpv, option.0, option.1)
            if status >= 0 { continue }
            // Optional in some MPVKit builds (e.g. hls-bitrate).
            mpvDebugLog(
                "setupMPV network option skipped name=\(option.0) status=\(status)"
            )
            recordDiagnosticEvent(
                "跳过网络选项",
                fields: ["选项": option.0, "错误码": String(status)]
            )
        }
    }
}
