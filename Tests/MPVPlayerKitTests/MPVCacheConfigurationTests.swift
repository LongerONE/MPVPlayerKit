import XCTest
@testable import MPVPlayerKit

final class MPVCacheConfigurationTests: XCTestCase {
    func testDemuxerHysteresisTracksEnabledCacheDuration() {
        XCTAssertEqual(MPVCacheConfiguration(isEnabled: true, duration: 10).demuxerHysteresisSeconds, 3)
        for duration in [30.0, 60.0, 120.0] {
            XCTAssertEqual(
                MPVCacheConfiguration(isEnabled: true, duration: duration).demuxerHysteresisSeconds,
                10
            )
        }
        var configuration = MPVCacheConfiguration(isEnabled: true, duration: 10)
        configuration.duration = 120
        XCTAssertEqual(configuration.demuxerHysteresisSeconds, 10)
        configuration.duration = 10
        XCTAssertEqual(configuration.demuxerHysteresisSeconds, 3)
        configuration.isEnabled = false
        XCTAssertEqual(configuration.demuxerHysteresisSeconds, 0)
        configuration.isEnabled = true
        XCTAssertEqual(configuration.demuxerHysteresisSeconds, 3)
    }

    func testMPVCacheOptionsHaveExplicitDemuxerMemoryLimits() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let setupSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MPVPlayerKit/MPVPlayerView+Setup.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(setupSource.contains("demuxerMaxBytes"))
        XCTAssertTrue(setupSource.contains("(\"demuxer-max-back-bytes\", Self.demuxerMaxBackBytes)"))
        XCTAssertTrue(setupSource.contains("(\"cache-on-disk\", \"no\")"))
        XCTAssertTrue(setupSource.contains("cacheConfiguration.isEnabled ? cacheConfiguration.duration : 0"))
        XCTAssertTrue(setupSource.contains("configuration.isEnabled ? configuration.duration : 0"))
        XCTAssertTrue(setupSource.contains("nonisolated static let demuxerMaxBytes = \"256MiB\""))
        XCTAssertTrue(setupSource.contains("nonisolated static let demuxerMaxBackBytes = \"0\""))
        let colorPolicySource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/MPVPlayerKit/MPVColorMappingPolicy.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(colorPolicySource.contains("demuxer-hysteresis-secs"))
    }

}
