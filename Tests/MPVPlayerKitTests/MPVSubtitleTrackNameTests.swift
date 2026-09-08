import XCTest
@testable import MPVPlayerKit

final class MPVSubtitleTrackNameTests: XCTestCase {
    func testUsesCompactLocalizedMetadata() {
        XCTAssertEqual(
            MPVPlayerView.subtitleTrackName(
                id: 3,
                languageCode: "chi",
                codec: "hdmv_pgs_subtitle",
                isForced: true,
                includeTrackID: true,
                localization: "zh-Hans"
            ),
            "简体中文·PGS·强制·轨道3"
        )
    }

    func testPrefersTitleAndExternalFilenameBasename() {
        XCTAssertEqual(
            MPVPlayerView.subtitleTrackName(
                id: 5,
                externalFilename: "/tmp/Movie.zh-Hans.ass",
                codec: "ass",
                includeTrackID: true,
                localization: "zh-Hans"
            ),
            "Movie.zh-Hans·ASS·轨道5"
        )
        XCTAssertEqual(
            MPVPlayerView.subtitleTrackName(
                id: 6,
                title: "导演评论",
                externalFilename: "/tmp/ignored.srt",
                codec: "subrip",
                localization: "zh-Hans"
            ),
            "导演评论·SRT"
        )
    }
}
