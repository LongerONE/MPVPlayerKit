import CoreMedia
import MediaPlayer
import UIKit
import XCTest
@testable import MPVPlayerKit

final class MPVSystemPlaybackControlsTests: XCTestCase {

    func testSeekTargetClampsFiniteDuration() {
        XCTAssertEqual(
            MPVSystemPlaybackControls.seekTarget(currentTime: 20, duration: 100, offset: 15),
            35
        )
        XCTAssertEqual(
            MPVSystemPlaybackControls.seekTarget(currentTime: 10, duration: 100, offset: -15),
            0
        )
        XCTAssertEqual(
            MPVSystemPlaybackControls.seekTarget(currentTime: 95, duration: 100, offset: 15),
            100
        )
    }

    func testSeekTargetAllowsUnknownDuration() {
        XCTAssertEqual(
            MPVSystemPlaybackControls.seekTarget(currentTime: 20, duration: 0, offset: 15),
            35
        )
        XCTAssertEqual(
            MPVSystemPlaybackControls.seekTarget(currentTime: 5, duration: .infinity, offset: -15),
            0
        )
    }

    func testStaticNowPlayingMetadataRefreshesWhenDurationBecomesKnown() {
        let url = URL(string: "https://example.com/media/Example%20Movie.mp4")!
        let liveMetadata = MPVNowPlayingStaticMetadata(url: url, duration: 0)
        let durationMetadata = MPVNowPlayingStaticMetadata(url: url, duration: 120)

        XCTAssertEqual(liveMetadata.title, "Example Movie.mp4")
        XCTAssertNil(liveMetadata.duration)
        XCTAssertNotEqual(liveMetadata, durationMetadata)
        XCTAssertNotEqual(
            durationMetadata,
            MPVNowPlayingStaticMetadata(
                url: URL(string: "https://example.com/media/Replacement.mp4"),
                duration: 120
            )
        )
        XCTAssertEqual(durationMetadata.duration, 120)

        let liveInfo = liveMetadata.nowPlayingInfo(ownerKey: "owner")
        XCTAssertEqual(liveInfo["owner"] as? Bool, true)
        XCTAssertEqual(liveInfo[MPMediaItemPropertyTitle] as? String, "Example Movie.mp4")
        XCTAssertEqual(liveInfo[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
        XCTAssertNil(liveInfo[MPMediaItemPropertyPlaybackDuration])
        XCTAssertNil(liveInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime])
        XCTAssertNil(liveInfo[MPNowPlayingInfoPropertyPlaybackRate])
        XCTAssertNil(liveInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate])

        let durationInfo = durationMetadata.nowPlayingInfo(ownerKey: "owner")
        XCTAssertEqual(durationInfo[MPMediaItemPropertyPlaybackDuration] as? TimeInterval, 120)
        XCTAssertNil(durationInfo[MPNowPlayingInfoPropertyIsLiveStream])
    }

    @MainActor
    func testCoordinatorPublishesBufferingTerminalAndOwnerStates() async {
        let center = MPNowPlayingInfoCenter.default()
        let previousInfo = center.nowPlayingInfo
        let bufferedPlayer = MPVPlayerView(frame: .zero)
        bufferedPlayer.currentTime = 12
        bufferedPlayer.duration = 120
        bufferedPlayer.playbackSpeed = 1.5
        bufferedPlayer.isPlaying = true
        let otherPlayer = MPVPlayerView(frame: .zero)
        otherPlayer.currentTime = 24
        otherPlayer.duration = 120
        otherPlayer.playbackSpeed = 2
        otherPlayer.isPlaying = true
        let coordinator = MPVSystemPlaybackCoordinator.shared
        defer {
            coordinator.deactivate(playerView: bufferedPlayer)
            coordinator.deactivate(playerView: otherPlayer)
            center.nowPlayingInfo = previousInfo
        }

        coordinator.activate(playerView: bufferedPlayer, isTimeAdvancing: false)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)

        coordinator.updateTimeAdvancing(playerView: bufferedPlayer, isTimeAdvancing: true)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)

        bufferedPlayer.stopSystemPlaybackProgress(keepingOwner: true)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertNotNil(center.nowPlayingInfo)

        bufferedPlayer.isPlaying = true
        bufferedPlayer.queue.sync {
            var snapshot = MPVBufferingSnapshot()
            snapshot.playbackIntent = .playing
            snapshot.pausedForCache = true
            _ = bufferedPlayer.bufferingStateMachine.reduce(.snapshot(snapshot))
        }
        coordinator.activate(playerView: otherPlayer, isTimeAdvancing: true)
        bufferedPlayer.activateSystemPlaybackControlsForPictureInPicture()
        for _ in 0 ..< 100 {
            if center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)

        coordinator.activate(playerView: otherPlayer, isTimeAdvancing: true)
        coordinator.updateTimeAdvancing(playerView: bufferedPlayer, isTimeAdvancing: false)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 2)

        otherPlayer.stopSystemPlaybackProgress(keepingOwner: false)
        XCTAssertNil(center.nowPlayingInfo)
    }

    func testSeekReplyAllowsAutoPlayOnlyAfterSuccessfulReply() {
        let request = MPVSeekRequest(
            requestID: "seek-1",
            targetTime: 120,
            autoPlay: true,
            playbackIntentGeneration: 0
        )

        XCTAssertEqual(
            MPVSeekReplyResolver.resolve(request: request, error: 0),
            MPVSeekReplyResolution(
                success: true,
                shouldAutoPlay: true,
                shouldRestoreTime: false
            )
        )
    }

    func testSeekReplyFailureRestoresTimeAndNeverAutoPlays() {
        let request = MPVSeekRequest(
            requestID: "seek-2",
            targetTime: 120,
            autoPlay: true,
            playbackIntentGeneration: 0
        )

        XCTAssertEqual(
            MPVSeekReplyResolver.resolve(request: request, error: -12),
            MPVSeekReplyResolution(
                success: false,
                shouldAutoPlay: false,
                shouldRestoreTime: true
            )
        )
    }

    func testUnknownSeekReplyDoesNotProduceAnAction() {
        XCTAssertNil(MPVSeekReplyResolver.resolve(request: nil, error: 0))
    }

    func testSeekReplyAutoPlayRequiresTheCurrentPlaybackIntent() {
        let request = MPVSeekRequest(
            requestID: "seek-3",
            targetTime: 120,
            autoPlay: true,
            playbackIntentGeneration: 4
        )
        let resolution = MPVSeekReplyResolver.resolve(request: request, error: 0)!

        XCTAssertTrue(
            MPVSeekReplyResolver.shouldAutoPlay(
                request: request,
                resolution: resolution,
                currentPlaybackIntentGeneration: 4
            )
        )
        XCTAssertFalse(
            MPVSeekReplyResolver.shouldAutoPlay(
                request: request,
                resolution: resolution,
                currentPlaybackIntentGeneration: 5
            )
        )
    }

    func testInitialPlaybackIntentCanAutoPlayAfterSuccessfulSeek() {
        let request = MPVSeekRequest(
            requestID: "initial-resume",
            targetTime: 120,
            autoPlay: true,
            playbackIntentGeneration: 0
        )
        let resolution = MPVSeekReplyResolver.resolve(request: request, error: 0)!

        XCTAssertTrue(
            MPVSeekReplyResolver.shouldAutoPlay(
                request: request,
                resolution: resolution,
                currentPlaybackIntentGeneration: 0
            )
        )
    }
}
