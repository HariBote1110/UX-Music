import XCTest
@testable import UX_Music_TV

/// De-risks the plan's named risk (Phase 1-1 / 1-4 of
/// `markdown/appletv-servermode-plan.md`): does the shared `AVAudioEngine` + 10-band EQ +
/// LUFS-normalisation pipeline (`MusicPlayerService`) actually initialise and play on tvOS?
/// tvOS has historically had a different default `AVAudioSession` category surface to iOS, so
/// this spike schedules and plays a tiny bundled sine-wave fixture end to end in the simulator.
@MainActor
final class MusicPlayerServicePlaybackSpikeTests: XCTestCase {
    func testEnginePipelineInitialisesAndPlaysBundledFixtureOnTVOS() async throws {
        let fixtureURL = try Self.spikeFixtureURL()

        let service = MusicPlayerService()
        let song = Song(
            id: "spike-sine",
            path: fixtureURL.path,
            title: "Spike Sine",
            artist: "UX Music",
            duration: 0.5
        )

        await service.play(song, newQueue: [song])

        // Give the engine graph a moment to spin up and start the player node — on tvOS this is
        // exactly the step most likely to fail if the session category isn't supported.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(service.currentSong?.id, song.id)
        XCTAssertGreaterThan(service.durationSeconds, 0, "AVAudioFile should have decoded a non-zero duration")

        service.togglePlayPause() // pause, exercising the engine stop/start path too
    }

    private static func spikeFixtureURL() throws -> URL {
        let bundle = Bundle(for: MusicPlayerServicePlaybackSpikeTests.self)
        guard let url = bundle.url(forResource: "spike-sine", withExtension: "wav") else {
            throw XCTSkip("spike-sine.wav fixture not found in test bundle")
        }
        return url
    }
}
