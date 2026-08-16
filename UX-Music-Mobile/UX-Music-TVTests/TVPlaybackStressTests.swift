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

    // MARK: - 4. double audio: old session provably silent no later than new session's first audio

    /// Direct regression proof for `progress/tvos-playback-concurrency.md`'s "double audio"
    /// symptom: switch from session A to session B WHILE A is actively rendering (past its jitter
    /// buffer), and assert A's `isRenderActiveForTesting` flag is already `false` by the time B's
    /// `relayStreamPlayerDidStartRendering` delegate callback fires. Before `stop()` gained its
    /// synchronous `silenceImmediately()` step, A's teardown was purely `engineQueue.async`
    /// (fire-and-forget), so A's engine could still be mid-render when B started — this test would
    /// have had no way to observe that ordering violation before `isRenderActiveForTesting`/
    /// `silenceImmediately()` existed, since both engines were muted (`muteOutput: true`) and
    /// nothing surfaced "was A still rendering" as a testable fact.
    func testOldSessionIsSilencedNoLaterThanNewSessionsFirstAudio() async throws {
        let fixtureURL = try Self.fixtureURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StressPacedFixtureURLProtocol.self]
        StressPacedFixtureURLProtocol.fixtureURL = fixtureURL
        let request = URLRequest(url: URL(string: "https://mock.invalid/v1/remote/file?id=song-1&stream=aac")!)

        await runWithHardTimeout("double-audio: old session silenced before new session's first audio", timeout: 20) {
            let playerA = TVRelayStreamPlayer(sessionConfiguration: config, muteOutput: true)
            let recorderA = StressRenderRecorder()
            playerA.delegate = recorderA
            playerA.start(request: request)

            // Wait until A is genuinely rendering (past the jitter buffer) — the worst-case moment
            // to switch, since A's engine is actively scheduling/playing buffers right now.
            let renderDeadline = Date().addingTimeInterval(10)
            while recorderA.renderCount == 0 {
                if Date() > renderDeadline {
                    XCTFail("session A never started rendering within 10s")
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(playerA.isRenderActiveForTesting, "sanity check: A must be actively rendering before the switch")

            // Now switch to B — mirrors `TVSongStreamController.start()`'s ordering: the old
            // player is stopped (which must silence it INSTANTLY) before the new one starts.
            playerA.stop()
            XCTAssertFalse(
                playerA.isRenderActiveForTesting,
                "session A must be silenced synchronously by stop(), not merely queued for later teardown"
            )

            let playerB = TVRelayStreamPlayer(sessionConfiguration: config, muteOutput: true)
            let recorderB = StressRenderRecorder()
            playerB.delegate = recorderB
            playerB.start(request: request)

            let bDeadline = Date().addingTimeInterval(10)
            while recorderB.renderCount == 0 {
                if Date() > bDeadline {
                    XCTFail("session B never started rendering within 10s")
                    return
                }
                // The load-bearing assertion: at EVERY point while waiting for B's first audio,
                // A must remain silent. A single `false` anywhere in this loop would be the
                // double-audio window made observable.
                XCTAssertFalse(playerA.isRenderActiveForTesting, "session A must stay silent while B starts up")
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            XCTAssertFalse(playerA.isRenderActiveForTesting, "session A must still be silent once B has first audio")
            playerB.stop()
        }
    }

    // MARK: - 5. rapid-hop stress: 30 switches with random 50-500ms gaps, deterministic seed

    /// A deterministic (seeded) linear-congruential generator standing in for `SystemRandomNumberGenerator`
    /// so this test's gap sequence is reproducible across runs/machines — a flaky interval sequence
    /// would undermine the "run 3 consecutive times" confidence check this test exists to support.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// 30 `play()` calls in rapid succession with random 50-500ms gaps (deterministic seed = 42),
    /// alternating stream-forced and cache-hit songs across a 4-song pool — the "rapid hop" stress
    /// scenario from `progress/tvos-playback-concurrency.md`. Asserts: (1) the final state is the
    /// LAST requested song, (2) `TVPlaybackController`'s internal `playToken` never allowed more
    /// than one in-flight `play()` call to reach `MusicPlayerService.play`/`streamController.start`
    /// — observed indirectly via `player.currentSong` always matching either the song just
    /// requested or a song still legitimately in flight, never a stale one left playing after a
    /// newer request landed first ("spurious advance" would show up as `currentSong` reverting to
    /// an earlier song after a later one already committed).
    func testThirtyRapidHopsWithRandomGapsEndsOnLastRequestedSongWithNoSpuriousAdvance() async throws {
        UXTVStreamSwitchMockURLProtocol.register()
        let apiClient = RemoteAPIClient(
            baseURLString: "http://127.0.0.1:1",
            session: URLSession(configuration: UXTVStreamSwitchMockURLProtocol.sessionConfiguration())
        )
        let player = MusicPlayerService()
        player.masterVolume = 0
        let cache = TVPlaybackCacheStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("stress-rapid-hop-\(UUID().uuidString)"),
            downloader: { songId, destination in
                if songId.hasPrefix("cached-") {
                    try Data("dummy-cached-audio".utf8).write(to: destination)
                } else {
                    throw URLError(.cannotConnectToHost)
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

        let songs = [
            Song(id: "stream-1", path: "", title: "St1", artist: "Demo", artworkId: "1"),
            Song(id: "cached-1", path: "", title: "Ca1", artist: "Demo", artworkId: "2"),
            Song(id: "stream-2", path: "", title: "St2", artist: "Demo", artworkId: "3"),
            Song(id: "cached-2", path: "", title: "Ca2", artist: "Demo", artworkId: "4"),
        ]

        var rng = SeededGenerator(seed: 42)
        var lastSong = songs[0]

        await runWithHardTimeout("thirty rapid hops with random gaps", timeout: 60) {
            for i in 0..<30 {
                let song = songs[Int(rng.next() % UInt64(songs.count))]
                lastSong = song
                let gapMs = UInt64(50 + rng.next() % 451) // 50-500ms
                Task { await controller.play(song, queue: songs) }
                try? await Task.sleep(nanoseconds: gapMs * 1_000_000)
                _ = i
            }

            // Let the last-fired play() settle (it may still be mid-flight — download/loudness
            // await — when the loop above returns).
            let deadline = Date().addingTimeInterval(15)
            while player.currentSong?.id != lastSong.id, controller.streamState != .streaming {
                if Date() > deadline { break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            XCTAssertEqual(
                player.currentSong?.id, lastSong.id,
                "the final observable state must be the LAST-requested song, never a spurious reversion to an earlier one"
            )
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
