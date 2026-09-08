import XCTest
import UIKit
@testable import MPVPlayerKit

final class MPVDiagnosticTests: XCTestCase {
    func testSourceClassificationDoesNotRetainURL() {
        let url = URL(string: "https://user:password@example.com/private/movie.mkv?token=secret#fragment")!
        XCTAssertEqual(MPVDiagnosticSource.resolve(.automatic, url: url), .remote)
        XCTAssertEqual(MPVDiagnosticSource.resolve(.automatic, url: URL(fileURLWithPath: "/private/movie.mkv")), .localFile)
        XCTAssertEqual(MPVDiagnosticSource.resolve(.automatic, url: URL(string: "http://127.0.0.1/vault/token/file")), .localHTTP)
        XCTAssertEqual(MPVDiagnosticSource.resolve(.vaultDecryption, url: url), .vaultDecryption)
    }

    func testBridgePreservesExplicitReleaseOptInAndSource() {
        let configuration = MPVPlayerConfiguration(
            url: URL(fileURLWithPath: "/private/movie.mkv"),
            diagnostics: .init(isEnabled: true, source: .vaultDecryption, host: .luwu)
        )
        XCTAssertEqual(configuration.bridgeDictionary["diagnosticsEnabled"] as? Bool, true)
        XCTAssertEqual(configuration.bridgeDictionary["diagnosticSource"] as? String, "vaultDecryption")
        XCTAssertEqual(configuration.bridgeDictionary["diagnosticHost"] as? String, "luwu")
    }

    func testDefaultOverrideUnderstandsLaunchArgumentStrings() {
        let defaults = UserDefaults.standard
        let key = "MPVPlayerKit.DiagnosticsEnabled"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        defaults.set("YES", forKey: key)
        XCTAssertTrue(MPVDiagnostics.isEnabledByDefault)
        defaults.set("NO", forKey: key)
        XCTAssertFalse(MPVDiagnostics.isEnabledByDefault)
    }

    func testCountersHandleUnavailableAndResets() {
        var counter = MPVDiagnosticCounter()
        XCTAssertEqual(counter.update(nil), "不可用")
        XCTAssertEqual(counter.update(10), "不可用")
        XCTAssertEqual(counter.update(14), "4")
        XCTAssertEqual(counter.update(2), "不可用")
        XCTAssertEqual(counter.update(2), "0")
        XCTAssertEqual(counter.update(nil), "不可用")
        XCTAssertEqual(counter.update(5), "不可用")
    }

    func testStaticMPVFieldsCacheSuccessfulReadsPerHandleAndRetryUnavailableValues() {
        let probe = MPVDiagnosticProbe(channel: MPVDiagnosticChannel())
        let firstHandle = try! XCTUnwrap(OpaquePointer(bitPattern: 1))
        let secondHandle = try! XCTUnwrap(OpaquePointer(bitPattern: 2))
        var firstHandleReads = 0

        XCTAssertNil(probe.staticMPVField("mpv-version", handle: firstHandle) {
            firstHandleReads += 1
            return nil
        })
        XCTAssertEqual(probe.staticMPVField("mpv-version", handle: firstHandle) {
            firstHandleReads += 1
            return "0.40.0"
        }, "0.40.0")
        XCTAssertEqual(probe.staticMPVField("mpv-version", handle: firstHandle) {
            firstHandleReads += 1
            return "should-not-read"
        }, "0.40.0")
        XCTAssertEqual(firstHandleReads, 2)

        XCTAssertEqual(probe.staticMPVField("mpv-version", handle: secondHandle) {
            "0.41.0"
        }, "0.41.0")
        probe.clearStaticMPVFieldCache()
        XCTAssertEqual(probe.staticMPVField("mpv-version", handle: secondHandle) {
            "0.42.0"
        }, "0.42.0")
    }

    func testProcessSamplerDoesNotInventFirstCPUValue() {
        var sampler = MPVDiagnosticProcessSampler()
        let first = sampler.sample()
        XCTAssertEqual(first["进程CPU百分比"], "不可用")
        XCTAssertGreaterThan(Int64(first["进程物理内存字节"] ?? "") ?? 0, 0)
        let second = sampler.sample()
        XCTAssertGreaterThanOrEqual(Double(second["进程CPU百分比"] ?? "") ?? -1, 0)
    }

    func testJSONLRotationAndGlobalBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MPVDiagnosticStore(directory: directory, segmentLimit: 1_024, totalLimit: 3_072, consoleEnabled: false)
        let sessionID = UUID()
        for index in 0..<30 {
            await store.append(record(sessionID: sessionID, sequence: index))
        }
        let files = try await store.files(sessionID: sessionID)
        XCTAssertGreaterThan(files.count, 1)
        var total = 0
        var sequences: [Int] = []
        for file in files {
            let data = try Data(contentsOf: file)
            total += data.count
            XCTAssertLessThanOrEqual(data.count, 1_024)
            XCTAssertEqual(data.last, 0x0A)
            for line in data.split(separator: 0x0A) {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                XCTAssertEqual(object["sessionID"] as? String, sessionID.uuidString)
                sequences.append(try XCTUnwrap(object["sequence"] as? Int))
            }
        }
        XCTAssertLessThanOrEqual(total, 3_072)
        XCTAssertEqual(sequences.last, 29)
        XCTAssertGreaterThan(sequences.first ?? 0, 0)
        let otherSession = UUID()
        await store.append(record(sessionID: otherSession, sequence: 1))
        let all = try await store.files()
        let allBytes = try all.reduce(0) { try $0 + Data(contentsOf: $1).count }
        XCTAssertLessThanOrEqual(allBytes, 3_072)
    }

    func testChannelFinishesWithSummaryAndRejectsLaterEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MPVDiagnosticStore(directory: directory, consoleEnabled: false)
        let channel = MPVDiagnosticChannel(store: store)
        channel.record("会话开始")
        channel.record("周期快照")
        channel.record("会话汇总", finish: true)
        channel.record("不应写入")
        var objects: [[String: Any]] = []
        for _ in 0..<100 {
            let files = try await store.files(sessionID: channel.sessionID)
            objects = try files.flatMap { file in
                try Data(contentsOf: file).split(separator: 0x0A).compactMap {
                    try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
                }
            }
            if objects.count == 3 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(objects.count, 3)
        XCTAssertEqual(objects.last?["event"] as? String, "会话汇总")
        let fields = objects.last?["fields"] as? [String: String]
        XCTAssertEqual(fields?["周期快照累计"], "1")
        XCTAssertEqual(fields?["事件累计"], "3")
    }

    @MainActor
    func testDisabledDiagnosticsCreateNoMonitorOrSession() async throws {
        let player = makePlayer(enabled: false)
        XCTAssertNil(player.diagnosticSessionID)
        XCTAssertNil(player.playbackView.diagnosticMonitor)
        let files = try await player.diagnosticLogFiles()
        XCTAssertTrue(files.isEmpty)
        player.stop()
    }

    @MainActor
    func testEnabledSessionSamplesAndStopsWithoutLeakingSource() async throws {
        let batteryWasEnabled = UIDevice.current.isBatteryMonitoringEnabled
        let player = makePlayer(enabled: true)
        let sessionID = try XCTUnwrap(player.diagnosticSessionID)
        var lines = ""
        for _ in 0..<80 {
            let files = try await player.diagnosticLogFiles()
            lines = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
            if lines.contains("周期快照") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(lines.contains("会话开始"))
        XCTAssertTrue(lines.contains("周期快照"))
        player.stop()
        XCTAssertNil(player.playbackView.diagnosticMonitor)
        XCTAssertEqual(UIDevice.current.isBatteryMonitoringEnabled, batteryWasEnabled)
        for _ in 0..<50 {
            let files = try await player.diagnosticLogFiles()
            lines = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
            if lines.contains("会话汇总") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(lines.contains("会话汇总"))
        XCTAssertFalse(lines.contains("private-video"))
        XCTAssertFalse(lines.contains("secret-token"))
        XCTAssertFalse(lines.contains("example.com"))
        XCTAssertEqual(player.diagnosticSessionID, sessionID)
        for file in try await player.diagnosticLogFiles() { try FileManager.default.removeItem(at: file) }
    }

    @MainActor
    func testMPVQueueStateNotificationCollectsDiagnosticsOnMainActor() async throws {
        let player = makePlayer(enabled: true)
        let view = player.playbackView
        let notification = expectation(description: "后台状态通知返回主线程")
        let observer = NotificationCenter.default.addObserver(
            forName: MPVPlayerKitNotification.didChangeState, object: view, queue: nil
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            notification.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            player.stop()
        }
        // 对应真机 setupMPV 在 MPV 串行队列发出 buffering 状态的路径。
        enqueueBufferingState(on: view)
        await fulfillment(of: [notification], timeout: 3)
        var fields: [String: String]?
        for _ in 0..<100 {
            for file in try await player.diagnosticLogFiles() {
                for line in try Data(contentsOf: file).split(separator: 0x0A) {
                    let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                    if object?["event"] as? String == "播放状态变化" {
                        fields = object?["fields"] as? [String: String]
                    }
                }
            }
            if fields != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(fields?["状态"], String(describing: MPVPlayerState.buffering))
        XCTAssertNotNil(fields?["热状态"])
    }

    nonisolated private func enqueueBufferingState(on view: MPVPlayerView) {
        // 使用非隔离的 GCD 工作项模拟既有 MPV 回调，不继承测试方法的 MainActor。
        let work = DispatchWorkItem { view.notifyState(.buffering) }
        view.queue.async(execute: work)
    }

    @MainActor
    private func makePlayer(enabled: Bool) -> MPVPlayer {
        // 动态 Swift Package 的无宿主测试将资源放在测试 bundle 中。
        let key = "PACKAGE_RESOURCE_BUNDLE_PATH"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, Bundle(for: Self.self).bundlePath, 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        return MPVPlayer(configuration: .init(
            url: URL(string: "https://example.com/private-video?token=secret-token")!,
            diagnostics: .init(isEnabled: enabled)
        ))
    }

    private func record(sessionID: UUID, sequence: Int) -> MPVDiagnosticRecord {
        MPVDiagnosticRecord(
            schemaVersion: 1, sessionID: sessionID, sequence: sequence, timestamp: Date(),
            uptimeSeconds: 10, elapsedSeconds: 1, event: "周期快照",
            fields: ["hwdec-current": "videotoolbox-copy", "热状态": "正常", "缺失属性": "不可用"]
        )
    }
}
