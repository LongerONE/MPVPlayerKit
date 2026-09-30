import Foundation
import XCTest
@testable import MPVPlayerKit

final class MPVSubtitleRequestTests: XCTestCase {
    @MainActor
    func testTimeoutCancelsDownloadAndCompletesOnlyOnce() async {
        let started = expectation(description: "download started")
        let cancelled = expectation(description: "download cancelled")
        let completed = expectation(description: "request completed")
        SubtitleRequestURLProtocol.state.prepare(started: started, cancelled: cancelled)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let player = MPVPlayer(url: URL(fileURLWithPath: "/video.mp4"))
        player.subtitleDownloadSession = session
        player.subtitleLoadTimeout = 0.3
        var completionCount = 0
        let requestID = player.loadClientSubtitle(from: URL(string: "https://example.com/private.srt")!,
                                                  headers: ["Authorization": "subtitle-only-token"]) { success in
            XCTAssertFalse(success)
            completionCount += 1
            completed.fulfill()
        }
        await fulfillment(of: [started, cancelled, completed], timeout: 3)
        XCTAssertEqual(SubtitleRequestURLProtocol.state.request()?.value(forHTTPHeaderField: "Authorization"),
                       "subtitle-only-token")
        player.cancelExternalSubtitleLoad(requestID)
        player.stop()
        XCTAssertEqual(completionCount, 1)
    }

    @MainActor
    func testHeaderDownloadKeepsLocalFileUntilStopAndPreservesMediaHeaders() async throws {
        let started = expectation(description: "download started")
        SubtitleRequestURLProtocol.state.prepare(started: started)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let player = MPVPlayer(url: URL(fileURLWithPath: "/video.mp4"), headers: ["X-Media-Token": "media-token"])
        player.subtitleDownloadSession = session
        let gate = DispatchSemaphore(value: 0)
        player.playbackView.queue.async { gate.wait() }
        defer { gate.signal() }
        var completions = 0
        let id = player.loadClientSubtitle(from: URL(string: "https://example.com/success.srt")!,
                                          headers: ["Authorization": "subtitle-token"]) { success in
            XCTAssertFalse(success)
            completions += 1
        }
        await fulfillment(of: [started], timeout: 3)
        for _ in 0..<100 where player.subtitleFiles[id.uuidString] == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let file = try XCTUnwrap(player.subtitleFiles[id.uuidString])
        XCTAssertEqual(try MPVSubtitleDocument.decode(Data(contentsOf: file), sourceURL: file).cues.first?.text, "subtitle")
        XCTAssertEqual(player.playbackView.headers, ["X-Media-Token": "media-token"])
        XCTAssertEqual(SubtitleRequestURLProtocol.state.request()?.value(forHTTPHeaderField: "Authorization"), "subtitle-token")
        player.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(completions, 1)
    }

    @MainActor
    func testCancellingOneMergedSubscriberKeepsOtherPending() async {
        let view = MPVPlayerView(frame: .zero)
        let transfer = MPVPlayerViewWeakTransfer(view)
        let remaining: [String]? = await withCheckedContinuation { continuation in
            view.queue.async {
                guard let view = transfer.value else { continuation.resume(returning: nil); return }
                view.pendingExternalSubtitleLoad = .init(userdata: 1, selectionEpoch: 0,
                    url: "file:///sub.srt", source: "sub.srt", usesOriginalStyle: false,
                    trackIDsBeforeLoad: [], previousSelection: .init(usesOriginalStyle: false,
                    subtitleID: nil, isVisible: false), requestIDs: ["first", "second"])
                view.cancelExternalSubtitleRequestOnMPVQueue(requestID: "first")
                continuation.resume(returning: view.pendingExternalSubtitleLoad?.requestIDs)
                view.pendingExternalSubtitleLoad = nil
            }
        }
        XCTAssertEqual(remaining, ["second"])
    }
}

private final class SubtitleRequestURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = RequestState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.didStart(request)
        if request.url?.lastPathComponent == "success.srt" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/x-subrip"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("1\n00:00:01,000 --> 00:00:02,000\nsubtitle".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.state.didCancel() }

    final class RequestState: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: URLRequest?
        private var started: XCTestExpectation?
        private var cancelled: XCTestExpectation?
        func prepare(started: XCTestExpectation, cancelled: XCTestExpectation? = nil) {
            lock.lock()
            defer { lock.unlock() }
            captured = nil
            self.started = started
            self.cancelled = cancelled
        }
        func didStart(_ request: URLRequest) {
            lock.lock()
            captured = request
            let expectation = started
            started = nil
            lock.unlock()
            expectation?.fulfill()
        }
        func didCancel() {
            lock.lock()
            let expectation = cancelled
            cancelled = nil
            lock.unlock()
            expectation?.fulfill()
        }
        func request() -> URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
    }
}
