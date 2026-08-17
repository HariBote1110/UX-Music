import XCTest
@testable import UX_Music_TV

/// Regression coverage for a real-device Apple TV report: play a CACHED song (local
/// `AVAudioEngine` path inside `MusicPlayerService`), then play a NON-CACHED song (stream-first
/// path via `TVSongStreamController`). Symptoms observed on-device: the seek bar oscillated
/// between the old and new song's position, and playback could not be stopped — the old song kept
/// audibly playing. Root cause: `MusicPlayerService.beginExternalPlayback` set
/// `isExternallyDriven = true` without stopping the still-running local engine or bumping
/// `playGeneration`, so the local `positionTimer` and the stream's `progressMirrorTask` both wrote
/// `positionSeconds` (see `progress/tv-cached-to-stream-switch-seekbar.md`).
@MainActor
final class TVPlaybackControllerCachedToStreamSwitchTests: XCTestCase {
    /// Level 1: exercise `MusicPlayerService` directly — a cached (local) song plays, then
    /// `beginExternalPlayback` is invoked directly (the exact call `TVPlaybackController` makes on
    /// a cache miss). The local engine must be fully silenced and never write `positionSeconds`
    /// again while external mirroring is active.
    func testBeginExternalPlaybackStopsLocalEngineAndStopsWritingPosition() async throws {
        let fixtureURL = try Self.spikeFixtureURL()
        let service = MusicPlayerService()
        service.masterVolume = 0
        let cachedSong = Song(
            id: "cached-song",
            path: fixtureURL.path,
            title: "Cached",
            artist: "UX Music",
            duration: 0.5
        )

        await service.play(cachedSong, newQueue: [cachedSong])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(service.hasActiveLocalAudioFileForTesting, "sanity check: local engine must actually be playing before the switch")

        let streamedSong = Song(id: "streamed-song", path: "", title: "Streamed", artist: "UX Music", artworkId: "s")
        service.beginExternalPlayback(song: streamedSong, durationSeconds: 100)

        XCTAssertFalse(service.hasActiveLocalAudioFileForTesting, "beginExternalPlayback must stop the local AVAudioEngine playback")

        service.updateExternalPlaybackProgress(seconds: 42)
        // Sleep across two 250ms position-timer ticks: if the local timer were still writing
        // `positionSeconds` from the (now-stale) local timeline, it would clobber this value.
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(service.positionSeconds, 42, accuracy: 0.5, "positionSeconds must be written only by the external stream mirror, never the local timer")
    }

    /// Level 2: the real repro path via `TVPlaybackController` — cached song A plays locally, then
    /// non-cached song B streams. Asserts the local engine is silenced and the seek bar does not
    /// oscillate/jump backwards once streaming begins.
    func testCachedThenNonCachedSwitchStopsLocalEngineAndSeekBarDoesNotOscillate() async throws {
        let fixtureURL = try Self.spikeFixtureURL()
        UXTVStreamSwitchMockURLProtocol.register()
        let apiClient = RemoteAPIClient(
            baseURLString: "http://127.0.0.1:1",
            session: URLSession(configuration: UXTVStreamSwitchMockURLProtocol.sessionConfiguration())
        )
        let player = MusicPlayerService()
        player.masterVolume = 0

        let songA = Song(id: "song-a-cached", path: "", title: "A", artist: "Demo", artworkId: "a")
        let songB = Song(id: "song-b-streamed", path: "", title: "B", artist: "Demo", artworkId: "b")

        let cache = TVPlaybackCacheStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("cached-to-stream-test-\(UUID().uuidString)"),
            downloader: { songId, destination in
                guard songId == songA.id else { throw URLError(.cannotConnectToHost) } // B is always a cache miss → streams
                try FileManager.default.copyItem(at: fixtureURL, to: destination)
            }
        )
        let controller = TVPlaybackController(
            client: apiClient,
            player: player,
            cache: cache,
            streamPlayerFactory: { TVRelayStreamPlayer(sessionConfiguration: UXTVStreamSwitchMockURLProtocol.sessionConfiguration(), muteOutput: true) }
        )

        await controller.play(songA, queue: [songA, songB]) // cache hit → local engine plays
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(player.hasActiveLocalAudioFileForTesting, "sanity check: song A must actually be playing locally before the switch")

        await controller.play(songB, queue: [songA, songB]) // cache miss → streams

        XCTAssertFalse(player.hasActiveLocalAudioFileForTesting, "switching to the streamed song must stop the local AVAudioEngine playback")

        try await waitUntilStreaming(controller)

        var samples: [Double] = []
        for _ in 0 ..< 4 {
            samples.append(player.positionSeconds)
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        for i in 1 ..< samples.count {
            XCTAssertGreaterThanOrEqual(samples[i], samples[i - 1], "seek bar must not jump backwards/oscillate once streaming: \(samples)")
        }
    }

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

    private static func spikeFixtureURL() throws -> URL {
        let bundle = Bundle(for: TVPlaybackControllerCachedToStreamSwitchTests.self)
        guard let url = bundle.url(forResource: "spike-sine", withExtension: "wav") else {
            throw XCTSkip("spike-sine.wav fixture not found in test bundle")
        }
        return url
    }
}
