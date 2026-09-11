import Foundation
#if canImport(Libmpv)
import Libmpv
#elseif canImport(libmpv)
import libmpv
#endif

extension MPVPlayerView {
    nonisolated func readMPVPlaybackUpdate(
        allowsPendingPlaybackPosition: Bool = false
    ) -> MPVPlaybackUpdate? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard allowsPendingPlaybackPosition || hasPendingPlaybackPositionUpdate() == false,
              let timeSnapshot = readMPVTimeSnapshot()
        else {
            return nil
        }
        let bufferedProgress = readMPVBufferedProgress(
            currentTime: timeSnapshot.currentTime,
            duration: timeSnapshot.duration
        )
        return makeMPVPlaybackUpdate(
            timeSnapshot: timeSnapshot,
            bufferedProgress: bufferedProgress
        )
    }

    nonisolated func makeMPVPlaybackUpdate(
        timeSnapshot: MPVPlaybackTimeSnapshot,
        bufferedProgress: Int?
    ) -> MPVPlaybackUpdate? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let bufferingSessionGeneration = currentMPVPlaybackUpdateSourceSession() else {
            return nil
        }
        return MPVPlaybackUpdate(
            timeSnapshot: timeSnapshot,
            bufferedProgress: bufferedProgress,
            bufferingSessionGeneration: bufferingSessionGeneration,
            playbackIntentGeneration: currentPlaybackIntentGeneration(),
            playbackPositionGeneration: currentPlaybackPositionGeneration()
        )
    }

    nonisolated func readMPVBufferedProgress(
        currentTime: TimeInterval,
        duration: TimeInterval?
    ) -> Int? {
        dispatchPrecondition(condition: .onQueue(queue))
        guard currentTime.isFinite,
              let duration,
              duration.isFinite,
              duration > 0.0,
              let bufferedEnd = readMPVBufferedEndTime(currentTime: currentTime)
        else {
            return nil
        }

        let timelineEnd = max(currentTime, bufferedEnd)
        guard timelineEnd.isFinite else { return nil }
        let rawProgress = timelineEnd / duration * 100.0
        return Int(min(max(rawProgress.rounded(.down), 0.0), 100.0))
    }

    nonisolated func publishBufferedProgress() {
        guard let update = readMPVPlaybackUpdate(allowsPendingPlaybackPosition: true) else { return }
        notifyOnMain {
            self.applyMPVBufferedProgressUpdate(update)
        }
    }

    func applyMPVTimeUpdate(_ update: MPVPlaybackUpdate) {
        guard currentBufferingSessionGeneration() == update.bufferingSessionGeneration,
              currentPlaybackIntentGeneration() == update.playbackIntentGeneration,
              isPlaybackPositionCurrent(update.playbackPositionGeneration),
              hasPendingPlaybackPositionUpdate() == false,
              isStopped() == false
        else {
            return
        }

        applyMPVTimeSnapshot(update.timeSnapshot)
        applyBufferedProgress(update.bufferedProgress)
        if isReadyToPlayReported() == false, duration > 0.0 {
            setReadyToPlayReported(true)
            notifyState(.readyToPlay)
            // 暂停期间也可能首次得知 duration；补一次系统播放信息。
            MPVSystemPlaybackCoordinator.shared.publish(playerView: self)
        }
    }

    func applyMPVBufferedProgressUpdate(_ update: MPVPlaybackUpdate) {
        guard currentBufferingSessionGeneration() == update.bufferingSessionGeneration,
              isStopped() == false
        else {
            return
        }
        applyBufferedProgress(update.bufferedProgress)
    }

    func applyBufferedProgress(_ progress: Int?) {
        let value = progress.map { NSNumber(value: $0) }
        guard bufferedProgress != value else { return }
        bufferedProgress = value
        notifyBufferedProgress(progress)
    }

    /// duration 可能仅在暂停时可知；首次有效时补发系统播放信息。
    nonisolated func publishDurationIfNewlyKnown() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard mpv != nil else { return }
        let total = getDouble(MPVProperty.duration)
        guard total.isFinite, total > 0.0 else { return }
        let sessionGeneration = currentBufferingSessionGeneration()
        let intentGeneration = currentPlaybackIntentGeneration()
        notifyOnMain {
            guard self.currentBufferingSessionGeneration() == sessionGeneration,
                  self.currentPlaybackIntentGeneration() == intentGeneration,
                  self.isStopped() == false,
                  self.duration <= 0.0
            else { return }
            self.duration = total
            MPVSystemPlaybackCoordinator.shared.publish(playerView: self)
        }
    }

    private nonisolated func readMPVBufferedEndTime(currentTime: TimeInterval) -> TimeInterval? {
        var state = mpv_node()
        if let mpv, mpv_get_property(mpv, MPVProperty.demuxerCacheState, MPV_FORMAT_NODE, &state) >= 0 {
            defer { mpv_free_node_contents(&state) }

            if let ranges = nodeValue(named: "seekable-ranges", in: state),
               ranges.format == MPV_FORMAT_NODE_ARRAY,
               let list = ranges.u.list,
               let values = list.pointee.values {
                var currentRangeEnd: TimeInterval?
                for index in 0 ..< Int(list.pointee.num) {
                    let range = values[index]
                    guard let start = nodeDouble(named: "start", in: range),
                          let end = nodeDouble(named: "end", in: range),
                          start.isFinite,
                          end.isFinite,
                          end >= start else { continue }
                    if currentTime >= start - 0.5, currentTime <= end + 0.5 {
                        currentRangeEnd = max(currentRangeEnd ?? end, end)
                    }
                }
                if let currentRangeEnd {
                    return currentRangeEnd
                }
            }

            if let cacheEnd = nodeDouble(named: "cache-end", in: state) {
                return cacheEnd
            }
        }

        return getDoubleIfAvailable(MPVProperty.demuxerCacheTime)
    }

    private nonisolated func nodeValue(named name: String, in node: mpv_node) -> mpv_node? {
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

    private nonisolated func nodeDouble(named name: String, in node: mpv_node) -> TimeInterval? {
        guard let value = nodeValue(named: name, in: node) else { return nil }
        switch value.format {
        case MPV_FORMAT_DOUBLE:
            return value.u.double_
        case MPV_FORMAT_INT64:
            return TimeInterval(value.u.int64)
        default:
            return nil
        }
    }
}
