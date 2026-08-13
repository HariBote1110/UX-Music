import XCTest
@testable import UX_Music_TV

/// Stress/regression proof for `progress/tvos-playback-concurrency.md`: ranks 1-2 of the audit
/// (`elapsedSeconds`'s 250ms poll, `pause()`/`resume()`) were fixed to avoid `MainActor →
/// engineQueue.sync`; this file is the load-bearing PROOF that the fix actually holds up under
/// realistic rapid-fire usage, not just the single-shot repros in
/// `TVPlaybackControllerStreamSwitchTests`/`TVRelayStreamPlayerLifecycleTests`. Every scenario is
/// wrapped in a hard timeout watchdog (`runWithHardTimeout`) so a genuine hang FAILS the test
/// (via `XCTestExpectation`'s own timeout) rather than wedging the whole suite — reaching the
/// assertions after the loop is itself part of the regression signal, same convention as the two
/// files above.
@MainActor
final class TVPlaybackStressTests: XCTestCase {
    // MARK: - Hard timeout watchdog

    /// Runs `operation` and fails the test if it hasn't finished within `timeout` — the caller's
    /// own assertions live inside `operation`, so a hang manifests as "expectation never fulfilled"
    /// (an XCTest failure) rather than the test method itself blocking forever. The abandoned
    /// `Task` is not force-cancelled on timeout (a genuine `engineQueue`/lock deadlock cannot be
    /// cancelled out of anyway); the point is that THIS test method — and the runner driving the
    /// rest of the suite — is never blocked waiting on it.
    private func runWithHardTimeout(
        _ description: String,
        timeout: TimeInterval,
        _ operation: @escaping () async -> Void
    ) async {
        let expectation = XCTestExpectation(description: description)
        Task {
            await operation()
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: timeout)
    }

    // MARK: - 1. 50 rapid play→switch cycles, alternating stream and cached sources

    /// Alternates between a song that always cache-MISSES (`stream-song`, forcing
    /// `TVSongStreamController`/`TVRelayStreamPlayer`'s stream-first path every time) and a song
    /// that cache-HITS after its first play (`cached-song`, exercising the plain
    /// `MusicPlayerService.play` fast path for the remaining 24 of its 25 requests) — 50 back-to-
    /// back `play()` calls with NO waiting between them, the harshest version of the "switch before
    /// the previous session even started rendering" repro this audit is about. The only assertion
    /// that matters is that this returns at all, ending on the LAST requested song.
    func testFiftyRapidPlaySwitchCyclesAlternatingStreamAndCachedEndsOnLastRequestedSong() async throws {
        UXTVStreamSwitchMockURLProtocol.register()
        let apiClient = RemoteAPIClient(
            baseURLString: "http://127.0.0.1:1",
            session: URLSession(configuration: UXTVStreamSwitchMockURLProtocol.sessionConfiguration())
        )
        let player = MusicPlayerService()
        player.masterVolume = 0
        let cache = TVPlaybackCacheStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("stress-alternate-\(UUID().uuidString)"),
            downloader: { songId, destination in
                if songId == "cached-song" {
                    try Data("dummy-cached-audio".utf8).write(to: destination)
                } else {
                    throw URLError(.cannotConnectToHost) // stream-song: always a cache miss → always streams
                }
            }
        )
        let controller = TVPlaybackController(
            client: apiClient,
            player: player,
            cache: cache,
            streamPlayerFactory: {
                TVRelayStreamPlayer(sessionConfiguration: UXTVStreamSwitchMockURLProtocol.sessionConfiguration(), muteOutput: true)
            }
        )

        let streamSong = Song(id: "stream-song", path: "", title: "Stream", artist: "Demo", artworkId: "s")
        let cachedSong = Song(id: "cached-song", path: "", title: "Cached", artist: "Demo", artworkId: "c")
        let queue = [streamSong, cachedSong]

        await runWithHardTimeout("fifty rapid play/switch cycles", timeout: 60) {
            var lastSong = streamSong
            for i in 0..<50 {
                let song = i.isMultiple(of: 2) ? streamSong : cachedSong
                lastSong = song
                await controller.play(song, queue: queue)
            }
            XCTAssertEqual(
                player.currentSong?.id, lastSong.id,
                "the final session must play the LAST-requested song, not a stale earlier one"
            )
        }
    }

    // MARK: - 2. stop-while-chunks-arriving, ×20, immediate restart

    /// Exercises `TVRelayStreamPlayer`'s `engineQueue`/`generation` race directly (no
    /// `TVPlaybackController` in the way): start a stream, stop it while chunks are still being
    /// paced in from the mock (well before the 0.75s jitter buffer would even let it start
    /// rendering — the worst-case interleaving for `handle`/`schedule` racing `stop()`'s teardown),
    /// then immediately start a NEW session on the same player instance. ×20. A final full
    /// start→render→stop proves the player is still healthy — not just "didn't crash" but "still
    /// actually works" — after the repeated churn.
    func testStopWhileChunksArrivingThenImmediateRestartTwentyTimesDoesNotHang() async throws {
        let fixtureURL = try Self.fixtureURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StressPacedFixtureURLProtocol.self]
        StressPacedFixtureURLProtocol.fixtureURL = fixtureURL

        let player = TVRelayStreamPlayer(sessionConfiguration: config, muteOutput: true)
        let recorder = StressRenderRecorder()
        player.delegate = recorder
        let request = URLRequest(url: URL(string: "https://mock.invalid/v1/remote/file?id=song-1&stream=aac")!)

        await runWithHardTimeout("stop-while-chunks-arriving x20", timeout: 40) {
            for _ in 0..<20 {
                player.start(request: request)
                // Well before the 0.75s jitter buffer fills — guarantees chunks are still arriving
                // (or at least in flight on `engineQueue`) when `stop()` lands.
                try? await Task.sleep(nanoseconds: 5_000_000)
                player.stop()
            }

            player.start(request: request)
            // Deliberately an `await`-friendly poll, NOT a blocking `XCTWaiter().wait(...)`
            // (`TVRelayStreamPlayerLifecycleTests`'s `RenderRecorder.wait` — fine there, a plain
            // synchronous `XCTestCase` method running on the real top-level main thread). THIS test
            // method runs as a `Task` on `@MainActor` (see `runWithHardTimeout`): the render
            // callback below is delivered via `DispatchQueue.main.async`, which needs the MainActor
            // executor to actually get a turn to run it. A synchronous blocking wait called from
            // inside an already-running MainActor `Task` does not reliably let that queued block
            // through — confirmed by instrumenting `TVRelayStreamPlayer` directly: the player fully
            // decoded and buffered well past the jitter threshold with zero errors, but the
            // delegate callback never arrived within the blocking wait's timeout. `await
            // Task.sleep(...)` between polls suspends this task and hands the MainActor executor
            // back, letting the pending main-queue block actually run.
            let deadline = Date().addingTimeInterval(10)
            while recorder.renderCount == 0, recorder.failureReason == nil {
                if Date() > deadline { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            player.stop()

            XCTAssertGreaterThan(recorder.renderCount, 0, "player must still be able to render after repeated stop/restart churn")
            XCTAssertNil(recorder.failureReason, "final session should not have failed: \(recorder.failureReason ?? "")")
        }
    }

    private static func fixtureURL() throws -> URL {
        let bundle = Bundle(for: TVPlaybackStressTests.self)
        guard let url = bundle.url(forResource: "relay-sample", withExtension: "aac") else {
            throw XCTSkip("relay-sample.aac fixture not found in test bundle")
        }
        return url
    }

    // MARK: - 3. pause/resume identity after 5 consecutive switches

    /// The literal "resume plays a stale earlier song" repro (`TVPlaybackControllerStreamSwitchTests`
    /// covers the ×1-switch case), taken to 5 consecutive switches: A→B→C→D→E, then pause/resume —
    /// must affect E ONLY, never A-D.
    func testPauseResumeIdentityAfterFiveConsecutiveSwitchesAffectsCurrentSongOnly() async throws {
        UXTVStreamSwitchMockURLProtocol.register()
        let apiClient = RemoteAPIClient(
            baseURLString: "http://127.0.0.1:1",
            session: URLSession(configuration: UXTVStreamSwitchMockURLProtocol.sessionConfiguration())
        )
        let player = MusicPlayerService()
        player.masterVolume = 0
        let cache = TVPlaybackCacheStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("stress-pause-resume-\(UUID().uuidString)"),
            downloader: { _, _ in throw URLError(.cannotConnectToHost) } // always a cache miss → always streams
        )
        let factory = StressTaggedStreamPlayerFactory()
        let controller = TVPlaybackController(
            client: apiClient,
            player: player,
            cache: cache,
            streamPlayerFactory: { factory.next() }
        )

        let songs = (0..<5).map { Song(id: "switch-song-\($0)", path: "", title: "S\($0)", artist: "Demo", artworkId: "s\($0)") }

        await runWithHardTimeout("pause/resume identity after 5 switches", timeout: 30) {
            for song in songs {
                await controller.play(song, queue: songs)
            }

            let deadline = Date().addingTimeInterval(10)
            while controller.streamState != .streaming {
                if Date() > deadline {
                    XCTFail("final (5th) stream never reached .streaming within 10s (state: \(controller.streamState))")
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            XCTAssertEqual(player.currentSong?.id, songs.last?.id, "Now Playing must mirror the CURRENT (5th) stream")
            XCTAssertEqual(factory.players.count, 5, "expected a fresh TVRelayStreamPlayer per play() call")

            player.togglePlayPause() // pause
            player.togglePlayPause() // resume

            for stale in factory.players.dropLast() {
                XCTAssertEqual(stale.pauseCallCount, 0, "a superseded session must never receive transport calls")
                XCTAssertEqual(stale.resumeCallCount, 0, "a superseded session must never receive transport calls")
            }
            let current = factory.players.last!
            XCTAssertGreaterThan(
                current.pauseCallCount + current.resumeCallCount, 0,
                "pause/resume must route to the CURRENT (5th) session"
            )
        }
    }
}

// MARK: - Test doubles (deliberately duplicated rather than shared — see `UXTVSongStreamMockURLProtocol`'s
// doc comment in `UXMusicTVApp.swift`: the test target can't share private test-file types across
// files any more cleanly than across targets)

/// Hands out `StressTaggedTVRelayStreamPlayer` instances so pause/resume routing can be asserted
/// without a live audio engine. Mirrors `TVPlaybackControllerStreamSwitchTests`'s
/// `TaggedStreamPlayerFactory`.
private final class StressTaggedStreamPlayerFactory {
    private(set) var players: [StressTaggedTVRelayStreamPlayer] = []

    func next() -> TVRelayStreamPlayer {
        let player = StressTaggedTVRelayStreamPlayer(
            sessionConfiguration: UXTVStreamSwitchMockURLProtocol.sessionConfiguration(),
            muteOutput: true
        )
        players.append(player)
        return player
    }
}

private final class StressTaggedTVRelayStreamPlayer: TVRelayStreamPlayer {
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0

    override func pause() {
        pauseCallCount += 1
        super.pause()
    }

    override func resume() {
        resumeCallCount += 1
        super.resume()
    }
}

/// Captures `TVRelayStreamPlayerDelegate` callbacks. Deliberately plain properties polled from an
/// `await Task.sleep` loop rather than an `XCTestExpectation`/`XCTWaiter` pair — see the call
/// site's comment for why a blocking wait doesn't reliably work from inside a `Task` running on
/// `@MainActor`.
private final class StressRenderRecorder: TVRelayStreamPlayerDelegate {
    private(set) var renderCount = 0
    private(set) var failureReason: String?

    func relayStreamPlayerDidStartRendering(_ player: TVRelayStreamPlayer) {
        renderCount += 1
    }

    func relayStreamPlayer(_ player: TVRelayStreamPlayer, didFailWith reason: String) {
        failureReason = reason
    }
}

/// Serves the bundled `relay-sample.aac` fixture as small, closely-paced chunks — tighter timing
/// than `TVRelayStreamPlayerLifecycleTests`'s `ChunkedFixtureURLProtocol` since this needs to run
/// 20+ start/stop cycles quickly while still reliably landing `stop()` mid-delivery.
private final class StressPacedFixtureURLProtocol: URLProtocol {
    static var fixtureURL: URL?

    /// Guards `isCancelled` between `stopLoading()` (called on whatever queue `URLSession` cancels
    /// on) and the delivery loop's background thread.
    private let cancelLock = NSLock()
    private var isCancelled = false

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

        let chunkSize = 2048
        var offset = 0
        DispatchQueue.global().async { [weak self] in
            while offset < data.count {
                guard let self else { return }
                self.cancelLock.lock()
                let cancelled = self.isCancelled
                self.cancelLock.unlock()
                guard !cancelled else { return } // `stop()` landed — do not keep occupying a global-queue thread
                let end = min(offset + chunkSize, data.count)
                self.client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                offset = end
                usleep(1000) // 1ms between chunks
            }
            self?.client?.urlProtocolDidFinishLoading(self!)
        }
    }

    /// `TVRelayStreamPlayer.stop()` cancels its `URLSessionDataTask`, which the session routes here.
    /// Unlike `TVRelayStreamPlayerLifecycleTests`'s `ChunkedFixtureURLProtocol` (a no-op — fine for
    /// that file's 2-iteration, fully-awaited-render scenario), this stress test runs 20 rapid
    /// start/stop cycles: leaving the delivery loop running after `stop()` would pile up that many
    /// concurrent blocking loops on `DispatchQueue.global()`'s shared thread pool, which can starve
    /// (rather than merely slow down) whichever session's chunks are dispatched last — a test-
    /// infrastructure artifact, not the production race this file exists to catch. Actually
    /// honouring cancellation keeps each mock session's footprint bounded to its own lifetime.
    override func stopLoading() {
        cancelLock.lock()
        isCancelled = true
        cancelLock.unlock()
    }
}
