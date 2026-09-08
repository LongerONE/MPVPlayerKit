import MediaPlayer

enum MPVSystemPlaybackControls {
    static let skipInterval: TimeInterval = 15

    static func seekTarget(
        currentTime: TimeInterval,
        duration: TimeInterval,
        offset: TimeInterval
    ) -> TimeInterval {
        let target = max(0, currentTime + offset)
        guard duration.isFinite, duration > 0 else { return target }
        return min(target, duration)
    }
}

struct MPVNowPlayingStaticMetadata: Equatable {
    let sourceURL: URL?
    let title: String
    let duration: TimeInterval?

    init(url: URL?, duration: TimeInterval) {
        self.init(url: url, normalizedDuration: Self.normalizedDuration(duration))
    }

    static func normalizedDuration(_ duration: TimeInterval) -> TimeInterval? {
        duration.isFinite && duration > 0 ? duration : nil
    }

    private init(url: URL?, normalizedDuration: TimeInterval?) {
        sourceURL = url
        let title = url?.lastPathComponent.removingPercentEncoding ?? ""
        self.title = title.isEmpty ? "MPVPlayerKit" : title
        duration = normalizedDuration
    }

    func nowPlayingInfo(ownerKey: String) -> [String: Any] {
        var info: [String: Any] = [
            ownerKey: true,
            MPMediaItemPropertyTitle: title,
        ]
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        return info
    }
}

@MainActor
final class MPVSystemPlaybackCoordinator {
    static let shared = MPVSystemPlaybackCoordinator()

    private static let ownerKey = "MPVPlayerKit.nowPlaying.owner"

    private struct StaticNowPlayingInfoCache {
        let metadata: MPVNowPlayingStaticMetadata
        let info: [String: Any]
    }

    private weak var activePlayerView: MPVPlayerView?
    private var commandTargetsInstalled = false
    private var staticNowPlayingInfoCache: StaticNowPlayingInfoCache?
    private var activePlayerIsAdvancing = false

    private init() {}

    func activate(playerView: MPVPlayerView, isTimeAdvancing: Bool) {
        guard playerView.systemPlaybackControlsEnabled else { return }
        installCommandTargetsIfNeeded()
        let isNewActivePlayer = activePlayerView !== playerView
        if isNewActivePlayer {
            invalidateStaticNowPlayingInfo()
        }
        activePlayerView = playerView
        activePlayerIsAdvancing = isTimeAdvancing
        publish(playerView: playerView)
    }

    func publish(playerView: MPVPlayerView) {
        guard playerView.systemPlaybackControlsEnabled,
              activePlayerView === playerView else { return }

        let speed = playerView.playbackSpeed.isFinite && playerView.playbackSpeed > 0
            ? playerView.playbackSpeed
            : 1.0
        var info = staticNowPlayingInfo(for: playerView)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, playerView.currentTime)
        info[MPNowPlayingInfoPropertyPlaybackRate] = playerView.isPlaying && activePlayerIsAdvancing ? speed : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = speed
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateTimeAdvancing(playerView: MPVPlayerView, isTimeAdvancing: Bool) {
        guard playerView.systemPlaybackControlsEnabled,
              activePlayerView === playerView else { return }
        activePlayerIsAdvancing = isTimeAdvancing
        publish(playerView: playerView)
    }

    func deactivate(playerView: MPVPlayerView) {
        guard activePlayerView === playerView else { return }
        activePlayerView = nil
        activePlayerIsAdvancing = false
        invalidateStaticNowPlayingInfo()
        if MPNowPlayingInfoCenter.default().nowPlayingInfo?[Self.ownerKey] as? Bool == true {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func installCommandTargetsIfNeeded() {
        guard commandTargetsInstalled == false else { return }
        commandTargetsInstalled = true

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: MPVSystemPlaybackControls.skipInterval)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: MPVSystemPlaybackControls.skipInterval)]

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play() ?? .commandFailed
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause() ?? .commandFailed
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayback() ?? .commandFailed
        }
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            self?.skip(event, direction: 1) ?? .commandFailed
        }
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            self?.skip(event, direction: -1) ?? .commandFailed
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            self?.changePlaybackPosition(event) ?? .commandFailed
        }
    }

    private func play() -> MPRemoteCommandHandlerStatus {
        guard let activePlayerView else { return .noSuchContent }
        activePlayerView.play()
        publish(playerView: activePlayerView)
        return .success
    }

    private func pause() -> MPRemoteCommandHandlerStatus {
        guard let activePlayerView else { return .noSuchContent }
        activePlayerView.pause()
        publish(playerView: activePlayerView)
        return .success
    }

    private func togglePlayback() -> MPRemoteCommandHandlerStatus {
        guard let activePlayerView else { return .noSuchContent }
        if activePlayerView.isPlaying {
            activePlayerView.pause()
        } else {
            activePlayerView.play()
        }
        publish(playerView: activePlayerView)
        return .success
    }

    private func skip(
        _ event: MPRemoteCommandEvent,
        direction: Double
    ) -> MPRemoteCommandHandlerStatus {
        let interval = (event as? MPSkipIntervalCommandEvent)?.interval
            ?? MPVSystemPlaybackControls.skipInterval
        return seek(by: direction * interval)
    }

    private func seek(by offset: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard let activePlayerView else { return .noSuchContent }
        let target = MPVSystemPlaybackControls.seekTarget(
            currentTime: activePlayerView.currentTime,
            duration: activePlayerView.duration,
            offset: offset
        )
        return seek(activePlayerView, to: target)
    }

    private func changePlaybackPosition(
        _ event: MPRemoteCommandEvent
    ) -> MPRemoteCommandHandlerStatus {
        guard let event = event as? MPChangePlaybackPositionCommandEvent else {
            return .commandFailed
        }
        return seek(to: event.positionTime)
    }

    private func seek(to position: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard let activePlayerView else { return .noSuchContent }
        let target = MPVSystemPlaybackControls.seekTarget(
            currentTime: 0,
            duration: activePlayerView.duration,
            offset: position
        )
        return seek(activePlayerView, to: target)
    }

    private func seek(
        _ playerView: MPVPlayerView,
        to target: TimeInterval
    ) -> MPRemoteCommandHandlerStatus {
        guard playerView.seek(["time": target] as NSDictionary) else {
            return .commandFailed
        }
        publish(playerView: playerView)
        return .success
    }

    private func staticNowPlayingInfo(for playerView: MPVPlayerView) -> [String: Any] {
        let sourceURL = playerView.url
        let duration = MPVNowPlayingStaticMetadata.normalizedDuration(playerView.duration)
        if let cache = staticNowPlayingInfoCache,
           cache.metadata.sourceURL == sourceURL,
           cache.metadata.duration == duration {
            return cache.info
        }
        let metadata = MPVNowPlayingStaticMetadata(
            url: sourceURL,
            duration: duration ?? 0
        )
        let info = metadata.nowPlayingInfo(ownerKey: Self.ownerKey)
        staticNowPlayingInfoCache = StaticNowPlayingInfoCache(metadata: metadata, info: info)
        return info
    }

    private func invalidateStaticNowPlayingInfo() {
        staticNowPlayingInfoCache = nil
    }
}
