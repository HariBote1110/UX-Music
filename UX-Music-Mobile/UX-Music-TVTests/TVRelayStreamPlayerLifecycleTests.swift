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

/// Regression coverage for the "通常の音源が数秒で次の曲へスキップされる" report
/// (`progress/tvos-playback.md` "受信完了≠再生完了" 追記).
///
/// Root cause: `didCompleteWithError(nil)` — the HTTP body ending — was reported straight through as
/// `relayStreamPlayerDidReachEndOfStream`, and `TVPlaybackController.advanceAfterStreamEnd` takes
/// that as "the track finished, advance the queue". But the host's `?stream=aac` endpoint runs
/// ffmpeg with no `-re` (`server/app_remote_stream.go`), so over LAN the whole track is transcoded
/// and sent in a few SECONDS regardless of its actual duration. The body therefore closes while
/// several minutes of decoded PCM are still queued on `playerNode` — audible playback is fine right
/// up until the auto-advance tears it down, which is exactly the reported symptom.
///
/// The fixture is ~6s of audio delivered in ~0.1s of wall time by `ChunkedFixtureURLProtocol`
/// (4096-byte chunks, 2ms apart), so the gap between "body complete" and "audio actually finished"
/// is ~60x — plenty of margin for a non-flaky assertion.
/// Every wait here goes through `XCTestExpectation`, never `Thread.sleep`: the delegate callbacks
/// are delivered via `DispatchQueue.main.async` and XCTest runs the test body ON the main thread, so
/// a `Thread.sleep` would block the very queue the callback needs and the test would observe "no
/// end-of-stream" no matter what the player did (this exact mistake made the first draft of
/// `testEndOfStreamIsNotReportedWhileBufferedAudioIsStillPlaying` pass against the KNOWN-broken
/// implementation). `wait(for:timeout:)` and `RunLoop.run(until:)` both pump the main run loop.
final class TVRelayStreamPlayerEndOfStreamTests: XCTestCase {
    /// The core assertion: 2.5s in, the entire HTTP body has long since arrived (~0.1s) but only
    /// ~2.5s of the ~6s fixture can possibly have been heard, so end-of-stream MUST NOT have been
    /// reported yet. The inverted expectation is armed BEFORE `start()` — arming it afterwards
    /// would race the (broken) implementation's ~0.12s report and silently pass again.
    func testEndOfStreamIsNotReportedWhileBufferedAudioIsStillPlaying() throws {
        let (player, recorder, request) = try Self.makeFixturePlayer()
        defer { player.stop() }

        let rendering = expectation(description: "didStartRendering")
        let premature = expectation(description: "no end-of-stream while audio is still playing")
        premature.isInverted = true
        recorder.renderingExpectation = rendering
        recorder.endOfStreamExpectation = premature

        player.start(request: request)
        wait(for: [rendering, premature], timeout: 2.5)

        XCTAssertNil(recorder.failureReason, "stream should not have failed: \(recorder.failureReason ?? "")")
    }

    /// The other half of the contract: it must still fire once the queued audio has genuinely
    /// drained, otherwise the queue would simply never advance and playback would dead-end.
    func testEndOfStreamIsReportedOnceTheBufferedAudioHasDrained() throws {
        let (player, recorder, request) = try Self.makeFixturePlayer()
        defer { player.stop() }

        let ended = expectation(description: "didReachEndOfStream")
        recorder.endOfStreamExpectation = ended

        let startedAt = Date()
        player.start(request: request)
        wait(for: [ended], timeout: 25)

        XCTAssertEqual(recorder.endOfStreamCount, 1, "expected exactly one end-of-stream report")
        XCTAssertGreaterThan(
            Date().timeIntervalSince(startedAt),
            5,
            "end-of-stream arrived before the ~6s fixture could have finished playing"
        )
    }

    /// `refreshCachedElapsedSeconds()` used to be reachable only from `schedule()`, so once the body
    /// had been fully received (and scheduling therefore stopped, ~0.1s in) `elapsedSeconds` froze —
    /// Now Playing's progress bar stalled a couple of seconds in even though audio kept playing.
    func testElapsedSecondsKeepsAdvancingAfterTheHTTPBodyHasFinished() throws {
        let (player, recorder, request) = try Self.makeFixturePlayer()
        defer { player.stop() }

        let rendering = expectation(description: "didStartRendering")
        recorder.renderingExpectation = rendering
        player.start(request: request)
        wait(for: [rendering], timeout: 10)

        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let firstSample = player.elapsedSeconds
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let secondSample = player.elapsedSeconds

        XCTAssertGreaterThan(firstSample, 0, "playback never advanced at all")
        XCTAssertGreaterThan(
            secondSample,
            firstSample,
            "elapsedSeconds froze after the HTTP body completed (\(firstSample) → \(secondSample))"
        )
    }

    private static func makeFixturePlayer() throws -> (TVRelayStreamPlayer, EndOfStreamRecorder, URLRequest) {
        let bundle = Bundle(for: TVRelayStreamPlayerEndOfStreamTests.self)
        guard let fixtureURL = bundle.url(forResource: "relay-sample", withExtension: "aac") else {
            throw XCTSkip("relay-sample.aac fixture not found in test bundle")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedFixtureURLProtocol.self]
        ChunkedFixtureURLProtocol.fixtureURL = fixtureURL

        let player = TVRelayStreamPlayer(sessionConfiguration: config, muteOutput: true)
        let recorder = EndOfStreamRecorder()
        player.delegate = recorder
        let request = URLRequest(url: URL(string: "https://mock.invalid/v1/remote/file?id=song-1&stream=aac")!)
        return (player, recorder, request)
    }
}

/// Expectation-driven delegate recorder for `TVRelayStreamPlayerEndOfStreamTests`. Deliberately
/// separate from `RenderRecorder` (whose count-based API predates these tests and is shared with
/// `TVRelayStreamPlayerLifecycleTests`) so that neither test's synchronisation style constrains the
/// other. No locking: every callback arrives on the main queue and every read happens on the main
/// thread between `wait`/`run(until:)` calls.
private final class EndOfStreamRecorder: TVRelayStreamPlayerDelegate {
    private(set) var endOfStreamCount = 0
    private(set) var failureReason: String?
    var renderingExpectation: XCTestExpectation?
    var endOfStreamExpectation: XCTestExpectation?

    func relayStreamPlayerDidStartRendering(_ player: TVRelayStreamPlayer) {
        renderingExpectation?.fulfill()
        renderingExpectation = nil // one session per test; a second fulfil would over-fulfil
    }

    func relayStreamPlayer(_ player: TVRelayStreamPlayer, didFailWith reason: String) {
        failureReason = reason
    }

    func relayStreamPlayerDidReachEndOfStream(_ player: TVRelayStreamPlayer) {
        endOfStreamCount += 1
        endOfStreamExpectation?.fulfill()
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
