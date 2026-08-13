import XCTest
@testable import UX_Music_TV

/// Regression coverage for the real-device crash reported in the brief: play an uncached song
/// (stream), back out (`stop()`), play the SAME song again (`start()`) → previously crashed with
/// `AVAEInternal.h:71 … [_nodes containsObject: node1] && [_nodes containsObject: node2]` inside
/// `AVAudioEngine.connect`. Root cause: `URLSessionDataDelegate` callbacks land on a background
/// delegate queue and were mutating `engine`/`playerNode` with zero synchronisation against
/// `stop()`, which is always called from the owning controller's main-actor context — a chunk
/// already in flight when the user backed out could run `schedule()`'s `engine.connect(...)`
/// concurrently with `stop()`'s `engine.detach(playerNode)`. The fix (`TVRelayStreamPlayer.engineQueue`
/// + a bumped `generation` counter) serialises every engine mutation and discards stale in-flight
/// frames after a `stop()`. See `progress/tvos-playback.md`.
final class TVRelayStreamPlayerLifecycleTests: XCTestCase {
    func testStartStopStartTwiceAgainstFixtureRendersBothTimesWithoutCrashing() throws {
        let fixtureURL = try Self.fixtureURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedFixtureURLProtocol.self]
        ChunkedFixtureURLProtocol.fixtureURL = fixtureURL

        let player = TVRelayStreamPlayer(sessionConfiguration: config, muteOutput: true)
        let recorder = RenderRecorder()
        player.delegate = recorder

        let request = URLRequest(url: URL(string: "https://mock.invalid/v1/remote/file?id=song-1&stream=aac")!)

        // First session: start, wait for rendering to begin, then stop — mirroring "user backs
        // out" mid-stream (not waiting for natural end of stream).
        recorder.expectRendering(count: 1)
        player.start(request: request)
        recorder.wait(timeout: 10)
        player.stop()

        // Second session on the SAME player instance, started immediately — the exact repro
        // ordering: `start` called while any residual delegate-queue work from the previous
        // session could still be in flight.
        recorder.expectRendering(count: 1)
        player.start(request: request)
        recorder.wait(timeout: 10)
        player.stop()

        XCTAssertEqual(recorder.renderCount, 2, "expected didStartRendering exactly once per session")
        XCTAssertNil(recorder.failureReason, "stream should not have failed: \(recorder.failureReason ?? "")")
    }

    private static func fixtureURL() throws -> URL {
        let bundle = Bundle(for: TVRelayStreamPlayerLifecycleTests.self)
        guard let url = bundle.url(forResource: "relay-sample", withExtension: "aac") else {
            throw XCTSkip("relay-sample.aac fixture not found in test bundle")
        }
        return url
    }
}

/// Captures `TVRelayStreamPlayerDelegate` callbacks onto an `XCTestExpectation` per session so the
/// test can synchronise on "first buffer scheduled" without a fixed sleep.
private final class RenderRecorder: TVRelayStreamPlayerDelegate {
    private(set) var renderCount = 0
    private(set) var failureReason: String?
    private var expectation: XCTestExpectation?

    func expectRendering(count: Int) {
        expectation = XCTestExpectation(description: "didStartRendering x\(count)")
        expectation?.expectedFulfillmentCount = count
    }

    func wait(timeout: TimeInterval) {
        guard let expectation else { return }
        _ = XCTWaiter().wait(for: [expectation], timeout: timeout)
    }

    func relayStreamPlayerDidStartRendering(_ player: TVRelayStreamPlayer) {
        renderCount += 1
        expectation?.fulfill()
    }

    func relayStreamPlayer(_ player: TVRelayStreamPlayer, didFailWith reason: String) {
        failureReason = reason
        expectation?.fulfill()
    }
}

/// Serves the bundled `relay-sample.aac` fixture as a chunked HTTP response, split into small
/// pieces delivered with a short delay between each — close enough to the real chunked-transfer
/// timing to exercise the delegate-queue/engine race the fix addresses, without needing a live
/// network host.
private final class ChunkedFixtureURLProtocol: URLProtocol {
    static var fixtureURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixtureURL = Self.fixtureURL, let data = try? Data(contentsOf: fixtureURL) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://mock.invalid")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/aac"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let chunkSize = 4096
        var offset = 0
        DispatchQueue.global().async { [weak self] in
            while offset < data.count {
                guard let self else { return }
                let end = min(offset + chunkSize, data.count)
                self.client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                offset = end
                usleep(2000) // 2ms between chunks: enough to interleave with stop() on the caller
            }
            self?.client?.urlProtocolDidFinishLoading(self!)
        }
    }

    override func stopLoading() {}
}
