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

@MainActor
final class MPVSystemPlaybackCoordinator {
    static let shared = MPVSystemPlaybackCoordinator()

    private static let ownerKey = "MPVPlayerKit.nowPlaying.owner"

    private weak var activePlayerView: MPVPlayerView?
    private var commandTargetsInstalled = false

    private init() {}

    func activate(playerView: MPVPlayerView) {
        installCommandTargetsIfNeeded()
        activePlayerView = playerView
        publish(playerView: playerView)
    }

    func publish(playerView: MPVPlayerView) {
        guard activePlayerView === playerView else { return }

        let speed = playerView.playbackSpeed.isFinite && playerView.playbackSpeed > 0
            ? playerView.playbackSpeed
            : 1.0
        var info: [String: Any] = [
            Self.ownerKey: true,
            MPMediaItemPropertyTitle: displayTitle(for: playerView),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, playerView.currentTime),
            MPNowPlayingInfoPropertyPlaybackRate: playerView.isPlaying ? speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
        ]
        if playerView.duration.isFinite, playerView.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = playerView.duration
        } else {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func deactivate(playerView: MPVPlayerView) {
        guard activePlayerView === playerView else { return }
        activePlayerView = nil
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

    private func displayTitle(for playerView: MPVPlayerView) -> String {
        let title = playerView.url?.lastPathComponent.removingPercentEncoding ?? ""
        return title.isEmpty ? "MPVPlayerKit" : title
    }
}
