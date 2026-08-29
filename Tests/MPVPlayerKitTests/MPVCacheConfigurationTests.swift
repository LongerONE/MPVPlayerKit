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
        XCTAssertTrue(setupSource.contains("nonisolated static let demuxerMaxBytes = \"256MiB\""))
        XCTAssertTrue(setupSource.contains("nonisolated static let demuxerMaxBackBytes = \"0\""))
    }

    func testDiskCacheLimitOptionsUseExpectedByteBudgets() {
        XCTAssertEqual(MPVCacheDiskLimit.defaultLimit, .fiveGB)
        XCTAssertEqual(MPVCacheDiskLimit.oneGB.bytes, Int64(1) * 1024 * 1024 * 1024)
        XCTAssertEqual(MPVCacheDiskLimit.twoGB.bytes, Int64(2) * 1024 * 1024 * 1024)
        XCTAssertEqual(MPVCacheDiskLimit.fiveGB.bytes, Int64(5) * 1024 * 1024 * 1024)
        XCTAssertEqual(MPVCacheDiskLimit.tenGB.bytes, Int64(10) * 1024 * 1024 * 1024)
        XCTAssertNil(MPVCacheDiskLimit.unlimited.bytes)

        let configuration = MPVCacheConfiguration(diskCacheLimit: .tenGB)
        XCTAssertEqual(
            configuration.bridgeDictionary["cacheDiskLimit"] as? NSNumber,
            NSNumber(value: MPVCacheDiskLimit.tenGB.rawValue)
        )
    }

    func testDiskCacheQuotaEvictsOldestChunk() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("mpv-cache-quota-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let oldURL = rootURL.appendingPathComponent("chunk-0.part")
        let middleURL = rootURL.appendingPathComponent("chunk-1.part")
        let newestURL = rootURL.appendingPathComponent("chunk-2.part")
        let chunk = Data(repeating: 1, count: 1024 * 1024)
        try chunk.write(to: oldURL)
        try chunk.write(to: middleURL)
        try chunk.write(to: newestURL)
        let now = Date()
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 24 * 60 * 60)],
            ofItemAtPath: oldURL.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-24 * 60 * 60)],
            ofItemAtPath: middleURL.path
        )
        try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: newestURL.path)

        let middleSize = Int64(try XCTUnwrap(
            middleURL.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize
        ))
        let newestSize = Int64(try XCTUnwrap(
            newestURL.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize
        ))
        MPVPersistentVideoCacheQuotaManager.shared.enforce(
            rootURL: rootURL,
            limitBytes: middleSize + newestSize
        )

        XCTAssertFalse(fileManager.fileExists(atPath: oldURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: middleURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: newestURL.path))
    }
}
