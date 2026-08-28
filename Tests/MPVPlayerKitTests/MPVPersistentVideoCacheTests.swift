import XCTest
@testable import MPVPlayerKit

final class MPVPersistentVideoCacheTests: XCTestCase {
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
