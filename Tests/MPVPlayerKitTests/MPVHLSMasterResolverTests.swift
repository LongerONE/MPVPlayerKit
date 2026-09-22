import XCTest

@testable import MPVPlayerKit

final class MPVHLSMasterResolverTests: XCTestCase {
    func testParseVariantsSkipsIFrameAndReadsAttributes() {
        let playlist = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aaclc-48-160",URI="audio/prog_index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=3307941,VIDEO-RANGE=SDR,CODECS="avc1.64001f,mp4a.40.5",RESOLUTION=1024x576,AUDIO="aaclc-48-160"
        Job-video-576/prog_index.m3u8
        #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=1,CODECS="avc1",RESOLUTION=864x486,URI="iframe/prog_index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=18352480,CODECS="hvc1.2.20000000.H150.B0,ec-3",RESOLUTION=3840x2160,AUDIO="ec3-48-768"
        Job-video-4k/prog_index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6301022,CODECS="avc1.640028,ec-3",RESOLUTION=1920x1080
        Job-video-1080/prog_index.m3u8
        """
        let base = URL(string: "https://example.com/hls/main.m3u8")!
        let variants = MPVHLSMasterResolver.parseVariants(in: playlist, baseURL: base)
        XCTAssertEqual(variants.count, 3)
        XCTAssertTrue(variants.allSatisfy { $0.url.absoluteString.contains("prog_index.m3u8") })
        XCTAssertFalse(variants.contains { $0.url.absoluteString.contains("iframe") })
    }

    func testPickVariantPrefersAVCUnder720p() {
        let base = URL(string: "https://example.com/hls/main.m3u8")!
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=18352480,CODECS="hvc1.2.20000000.H150.B0",RESOLUTION=3840x2160
        Job-4k/prog_index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6301022,CODECS="avc1.640028",RESOLUTION=1920x1080
        Job-1080/prog_index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2431160,CODECS="avc1.64001f",RESOLUTION=864x486
        Job-576/prog_index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3307941,CODECS="avc1.64001f",RESOLUTION=1024x576
        Job-720ish/prog_index.m3u8
        """
        let variants = MPVHLSMasterResolver.parseVariants(in: playlist, baseURL: base)
        let picked = MPVHLSMasterResolver.pickVariant(from: variants)
        XCTAssertEqual(picked?.width, 1024)
        XCTAssertTrue(picked?.isAVC == true)
    }

    func testNeedsResolutionDetectsM3U8() {
        XCTAssertTrue(
            MPVHLSMasterResolver.needsResolution(
                URL(string: "https://example.com/a/main.m3u8")!
            )
        )
        XCTAssertFalse(
            MPVHLSMasterResolver.needsResolution(
                URL(string: "https://example.com/a/video.mp4")!
            )
        )
    }
}
