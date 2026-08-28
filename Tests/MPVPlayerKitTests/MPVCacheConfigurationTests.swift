import XCTest
@testable import MPVPlayerKit

final class MPVCacheConfigurationTests: XCTestCase {
    func testMPVCacheOptionsHaveExplicitDemuxerMemoryLimits() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let setupSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MPVPlayerKit/MPVPlayerView+Setup.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(setupSource.contains("(\"demuxer-max-bytes\", Self.demuxerMaxBytes)"))
        XCTAssertTrue(setupSource.contains("(\"demuxer-max-back-bytes\", Self.demuxerMaxBackBytes)"))
        XCTAssertTrue(setupSource.contains("nonisolated static let demuxerMaxBytes = \"64MiB\""))
        XCTAssertTrue(setupSource.contains("nonisolated static let demuxerMaxBackBytes = \"0\""))
    }
}
