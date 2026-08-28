import XCTest
@testable import MPVPlayerKit

final class MPVPersistentVideoCacheTests: XCTestCase {
    func testHTTPRangeResponseCollectorCapsUnexpectedLargeResponse() throws {
        let collector = MPVHTTPRangeResponseCollector(maximumBodyBytes: 8)
        let session = URLSession(configuration: .ephemeral)
        let requestURL = try XCTUnwrap(URL(string: "https://example.com/video.mkv"))
        let task = session.dataTask(with: requestURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "55000000000"]
            )
        )

        collector.urlSession(session, dataTask: task, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .allow)
        }
        collector.urlSession(
            session,
            dataTask: task,
            didReceive: Data(repeating: 1, count: 16)
        )
        collector.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))

        let result = collector.result()
        XCTAssertEqual(result.data.count, 8)
        XCTAssertTrue(result.bodyLimitExceeded)
        XCTAssertEqual(result.response?.expectedContentLength, 55_000_000_000)
    }

    func testCacheKeyIgnoresAuthenticationAndPlaybackSessionValues() throws {
        let firstURL = try XCTUnwrap(
            URL(string: "https://example.com/Videos/1/stream?MediaSourceId=source&PlaySessionId=first&api_key=token-a")
        )
        let secondURL = try XCTUnwrap(
            URL(string: "https://example.com/Videos/1/stream?MediaSourceId=source&PlaySessionId=second&api_key=token-b")
        )

        let first = MPVPersistentVideoCacheContext(
            sourceURL: firstURL,
            headers: ["X-Emby-Token": "token-a"],
            userAgent: "Temby/1.0",
            cacheDirectoryURL: FileManager.default.temporaryDirectory
        )
        let second = MPVPersistentVideoCacheContext(
            sourceURL: secondURL,
            headers: ["X-Emby-Token": "token-b"],
            userAgent: "Temby/1.0",
            cacheDirectoryURL: FileManager.default.temporaryDirectory
        )

        XCTAssertEqual(first.cacheKey, second.cacheKey)
    }

    func testCacheKeySeparatesDifferentMediaSources() throws {
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/Videos/1/stream"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/Videos/2/stream"))
        let directory = FileManager.default.temporaryDirectory

        let first = MPVPersistentVideoCacheContext(
            sourceURL: firstURL,
            headers: [:],
            userAgent: nil,
            cacheDirectoryURL: directory
        )
        let second = MPVPersistentVideoCacheContext(
            sourceURL: secondURL,
            headers: [:],
            userAgent: nil,
            cacheDirectoryURL: directory
        )

        XCTAssertNotEqual(first.cacheKey, second.cacheKey)
    }
}
