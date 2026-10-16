import Foundation
import MPVPlayerKit
import UIKit

/// 绕过 XCTest 启动服务的 Demo 诊断入口，仍调用真实播放器公共 API。
@MainActor enum SubtitleRegression {
    static func run(in controller: UIViewController) async {
        var checks: [String: Bool] = [:]
        var players: [MPVPlayer] = []
        func fixture(_ name: String) -> URL {
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "SubtitleFixtures")!
        }
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }
        func make() -> MPVPlayer {
            let player = MPVPlayer(configuration: MPVPlayerConfiguration(
                url: fixture("dual-subtitles.mp4"), forceSoftwareDecode: true))
            players.append(player)
            player.playbackView.frame = controller.view.bounds
            controller.view.addSubview(player.playbackView)
            player.play()
            return player
        }
        func load(_ name: String, slot: MPVSubtitleSlot, player: MPVPlayer) async -> Bool {
            var result: Bool?
            player.loadExternalSubtitle(from: fixture(name), in: slot) { result = $0 }
            let finished = await wait { result != nil }
            return finished && result == true
        }
        let first = make()
        checks["videoReady"] = await wait { first.duration > 0 && first.currentTime > 0 }
        checks["secondaryLoaded"] = await load("secondary.vtt", slot: .secondary, player: first)
        let document = try? MPVSubtitleDocument.decode(Data(contentsOf: fixture("primary.srt")),
                                                      sourceURL: fixture("primary.srt"))
        first.selectClientSubtitle(document)
        first.setSubtitleDelay(1.25, in: .primary)
        first.setSubtitleDelay(1.5, in: .secondary)
        first.setSubtitlesVisible(false, in: .secondary)
        checks["beforeSnapshot"] = await wait {
            first.subtitleState(in: .primary).delay == 1.25 &&
            first.subtitleState(in: .secondary).delay == 1.5 &&
            !first.subtitleState(in: .secondary).visible
        }
        let snapshot = first.subtitleSessionSnapshot()
        first.stop()
        first.playbackView.removeFromSuperview()
        let rebuilt = make()
        rebuilt.restoreSubtitleSession(snapshot)
        checks["documentAndSecondaryRestored"] = await wait {
            let primary = rebuilt.subtitleState(in: .primary)
            let secondary = rebuilt.subtitleState(in: .secondary)
            return !primary.isNative && primary.trackID == nil && primary.delay == 1.25 &&
                secondary.trackID != nil && !secondary.visible && secondary.delay == 1.5
        }
        rebuilt.setSubtitlesVisible(true, in: .secondary)
        rebuilt.seek(to: 2)
        checks["restoredSecondaryText"] = await wait {
            rebuilt.currentSubtitleText(in: .secondary)?.contains("SECONDARY_ONE") == true
        }
        rebuilt.pause()
        rebuilt.playbackView.configure(["url": fixture("dual-subtitles.mp4").absoluteString,
                                        "forceSoftwareDecode": true])
        rebuilt.play()
        checks["configureClearsSession"] = await wait {
            let state = rebuilt.subtitleState(in: .secondary)
            return rebuilt.duration > 0 && rebuilt.currentTime > 0 &&
                state.trackID == nil && state.sourceID == nil && state.delay == 0
        }
        players.forEach { $0.stop() }
        let report: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 },
                                   "runtime": UIDevice.current.systemVersion, "dependency": "MPVKit 1.0.0"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("dual-subtitle-regression.json")
            try? data.write(to: url)
            print("DUAL_SUBTITLE_REGRESSION \(String(decoding: data, as: UTF8.self))")
        }
        let label = UILabel(frame: controller.view.bounds)
        label.text = checks.values.allSatisfy { $0 } ? "双字幕回归通过" : "双字幕回归失败"
        label.textColor = .white
        label.backgroundColor = .black
        label.textAlignment = .center
        controller.view.addSubview(label)
    }
}
