import XCTest

@testable import MPVPlayerKit

final class MPVHLSMasterResolverTests: XCTestCase {
    func testSyncResolutionReturnsVariant() {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.com/master.m3u8")!
        XCTAssertEqual(MPVHLSMasterResolver.resolveMediaPlaylistSync(from: url, session: session),
                       URL(string: "https://example.com/video.m3u8")!)
    }

    func testSyncCancellationStopsPendingRequestPromptly() {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.com/stalled.m3u8")!
        let started = Date.timeIntervalSinceReferenceDate
        let result = MPVHLSMasterResolver.resolveMediaPlaylistSync(from: url, session: session) {
            Date.timeIntervalSinceReferenceDate - started >= 0.2
        }
        XCTAssertEqual(result, url)
        XCTAssertLessThan(Date.timeIntervalSinceReferenceDate - started, 2)
        XCTAssertEqual(ResolverURLProtocol.cancelled.wait(timeout: .now() + 2), .success)
    }

    func testSyncTimeoutCancelsPendingRequest() {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.com/stalled.m3u8")!
        let started = Date.timeIntervalSinceReferenceDate
        XCTAssertEqual(MPVHLSMasterResolver.resolveMediaPlaylistSync(from: url, session: session), url)
        XCTAssertGreaterThanOrEqual(Date.timeIntervalSinceReferenceDate - started, 14)
        XCTAssertLessThan(Date.timeIntervalSinceReferenceDate - started, 18)
        XCTAssertEqual(ResolverURLProtocol.cancelled.wait(timeout: .now() + 2), .success)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResolverURLProtocol.self]
        return URLSession(configuration: configuration)
    }

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

private final class ResolverURLProtocol: URLProtocol, @unchecked Sendable {
    static let cancelled = DispatchSemaphore(value: 0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.lastPathComponent != "stalled.m3u8" else { return }
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000,CODECS="avc1",RESOLUTION=1280x720
        video.m3u8
        """
        client?.urlProtocol(self, didLoad: Data(playlist.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if request.url?.lastPathComponent == "stalled.m3u8" { Self.cancelled.signal() }
    }
}
