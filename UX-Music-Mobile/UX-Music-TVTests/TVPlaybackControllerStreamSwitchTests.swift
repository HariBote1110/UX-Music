import XCTest
@testable import UX_Music_TV

/// Regression coverage for two real-device defects reported while streaming (`progress/tvos-playback.md`
/// "engineQueue↔MainActor デッドロック" 追記):
///
/// 1. Switching to a DIFFERENT song while one is mid-stream must never hang the UI — exercised at
///    the `TVRelayStreamPlayer` level in `TVRelayStreamPlayerLifecycleTests`; here we exercise it at
///    the `TVPlaybackController` level (the real call path: `play(A)` → immediately `play(B)`).
/// 2. After switching songs, `togglePlayPause()` (pause then resume) must affect the CURRENT
///    session's stream, never a stale earlier one — the literal "resume plays the first-ever song"
///    repro.
@MainActor
final class TVPlaybackControllerStreamSwitchTests: XCTestCase {
    private func makeController(streamPlayers: TaggedStreamPlayerFactory) -> (TVPlaybackController, MusicPlayerService) {
        UXTVStreamSwitchMockURLProtocol.register()
        let apiClient = RemoteAPIClient(
            baseURLString: "http://127.0.0.1:1",
            session: URLSession(configuration: UXTVStreamSwitchMockURLProtocol.sessionConfiguration())
        )
        let player = MusicPlayerService()
        player.masterVolume = 0
        let cache = TVPlaybackCacheStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("stream-switch-test-\(UUID().uuidString)"),
            downloader: { _, _ in throw URLError(.cannotConnectToHost) } // always a cache miss → always streams
        )
        let controller = TVPlaybackController(
            client: apiClient,
            player: player,
            cache: cache,
            streamPlayerFactory: { streamPlayers.next() }
        )
        return (controller, player)
    }

    /// `TVSongStreamController.togglePlayPause()` is a no-op until `didStartPlaying` (set once
    /// `TVRelayStreamPlayer` has actually decoded+buffered enough PCM to render — see
    /// `relayStreamPlayerDidStartRendering`), which is asynchronous and NOT awaited by
    /// `TVPlaybackController.play()` (streaming starts in the background so `play()` can return as
    /// soon as the request is in flight, per its "再生開始レイテンシ" design). Tests that need to
    /// exercise pause/resume must poll `controller.streamState` up to `.streaming` first.
    private func waitUntilStreaming(_ controller: TVPlaybackController, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.streamState != .streaming {
            if Date() > deadline {
                XCTFail("stream never reached .streaming within \(timeout)s (state: \(controller.streamState))")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Repro ordering from the real-device report: start streaming song A, then — WITHOUT waiting
    /// for A to finish or even start rendering — immediately play song B. Before the
    /// `engineQueue.async` fix (`TVRelayStreamPlayer.start()`/`stop()` used to be `engineQueue.sync`,
    /// always called from the MainActor), this call path is exactly where a hang was reported.
    /// `await` completing at all (rather than the test timing out) is the regression signal.
    func testSwitchingToADifferentSongMidStreamDoesNotHang() async throws {
        let songA = Song(id: "song-a", path: "", title: "A", artist: "Demo", artworkId: "a")
        let songB = Song(id: "song-b", path: "", title: "B", artist: "Demo", artworkId: "b")
        let factory = TaggedStreamPlayerFactory()
        let (controller, _) = makeController(streamPlayers: factory)

        await controller.play(songA, queue: [songA, songB])
        // Deliberately not waiting for A to start rendering — the exact hang repro ordering.
        await controller.play(songB, queue: [songA, songB])

        // If `play(B)` above ever hung inside `TVRelayStreamPlayer.stop()`/`start()`, this line is
        // unreachable and XCTest's own test-method timeout fails the test — reaching here at all is
        // the assertion.
        XCTAssertEqual(factory.players.count, 2, "expected a fresh TVRelayStreamPlayer per play() call")
    }

    /// The literal "resume plays the FIRST-ever song" repro: A(stream) → B(stream) → pause → resume
    /// must resume B, never A.
    func testPauseThenResumeAfterSwitchingStreamsAffectsCurrentSongOnly() async throws {
        let songA = Song(id: "song-a", path: "", title: "A", artist: "Demo", artworkId: "a")
        let songB = Song(id: "song-b", path: "", title: "B", artist: "Demo", artworkId: "b")
        let factory = TaggedStreamPlayerFactory()
        let (controller, player) = makeController(streamPlayers: factory)

        await controller.play(songA, queue: [songA, songB])
        await controller.play(songB, queue: [songA, songB])
        try await waitUntilStreaming(controller) // B must actually be rendering before pause/resume mean anything

        XCTAssertEqual(player.currentSong?.id, "song-b", "Now Playing must mirror the CURRENT stream")

        player.togglePlayPause() // pause
        player.togglePlayPause() // resume

        let playerA = factory.players[0]
        let playerB = factory.players[1]
        XCTAssertEqual(playerA.pauseCallCount, 0, "the FIRST session's player must never receive transport calls once superseded")
        XCTAssertEqual(playerA.resumeCallCount, 0, "the FIRST session's player must never receive transport calls once superseded")
        XCTAssertGreaterThan(playerB.pauseCallCount + playerB.resumeCallCount, 0, "pause/resume must route to the CURRENT (B) session")
    }
}

/// Hands out `TaggedTVRelayStreamPlayer` instances (real `TVRelayStreamPlayer` subclass wrapping
/// call counts) so pause/resume routing can be asserted without a live audio engine.
private final class TaggedStreamPlayerFactory {
    private(set) var players: [TaggedTVRelayStreamPlayer] = []

    func next() -> TVRelayStreamPlayer {
        let player = TaggedTVRelayStreamPlayer(
            sessionConfiguration: UXTVStreamSwitchMockURLProtocol.sessionConfiguration(),
            muteOutput: true
        )
        players.append(player)
        return player
    }
}

private final class TaggedTVRelayStreamPlayer: TVRelayStreamPlayer {
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

/// Serves `/v1/remote/file` with the bundled fixture (chunked, small delay) for ANY song id, and a
/// benign `found: false` for `/v1/remote/lyrics`/empty loudness map — enough for
/// `TVPlaybackController.play()`'s stream-first branch to run end to end without a live host.
final class UXTVStreamSwitchMockURLProtocol: URLProtocol {
    static func register() {
        URLProtocol.registerClass(UXTVStreamSwitchMockURLProtocol.self)
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UXTVStreamSwitchMockURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool {
        let path = request.url?.path
        return path == "/v1/remote/file" || path == "/v1/remote/loudness"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/v1/remote/loudness" {
            let data = "{}".data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        guard let fixtureURL = Bundle(for: UXTVStreamSwitchMockURLProtocol.self).url(forResource: "relay-sample", withExtension: "aac"),
              let data = try? Data(contentsOf: fixtureURL)
        else {
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
                usleep(2000)
            }
            self?.client?.urlProtocolDidFinishLoading(self!)
        }
    }

    override func stopLoading() {}
}
