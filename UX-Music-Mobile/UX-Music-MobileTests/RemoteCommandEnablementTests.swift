import XCTest
@testable import UX_Music_Mobile

final class RemoteCommandEnablementTests: XCTestCase {
    func testNoSongDisablesEverythingExceptToggleStillFollowsHasSong() {
        let state = RemoteCommandEnablement.state(hasSong: false, isPlaying: false)
        XCTAssertFalse(state.playEnabled)
        XCTAssertFalse(state.pauseEnabled)
        XCTAssertFalse(state.toggleEnabled)
    }

    func testSongPlayingEnablesPauseOnlyNotPlay() {
        let state = RemoteCommandEnablement.state(hasSong: true, isPlaying: true)
        XCTAssertFalse(state.playEnabled)
        XCTAssertTrue(state.pauseEnabled)
        XCTAssertTrue(state.toggleEnabled)
    }

    func testSongPausedEnablesPlayOnlyNotPause() {
        let state = RemoteCommandEnablement.state(hasSong: true, isPlaying: false)
        XCTAssertTrue(state.playEnabled)
        XCTAssertFalse(state.pauseEnabled)
        XCTAssertTrue(state.toggleEnabled)
    }

    func testPlayAndPauseAreNeverBothEnabled() {
        for hasSong in [true, false] {
            for isPlaying in [true, false] {
                let state = RemoteCommandEnablement.state(hasSong: hasSong, isPlaying: isPlaying)
                XCTAssertFalse(state.playEnabled && state.pauseEnabled)
            }
        }
    }
}

/// Periodic (4 Hz) Now Playing refreshes must only reach `MPNowPlayingInfoCenter` when something
/// changed; iOS interpolates elapsed time itself from elapsed + rate.
final class NowPlayingPublicationTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    private func publication(
        songId: String? = "a", title: String = "T", artist: String = "A", album: String = "Al",
        duration: Double = 200, isPlaying: Bool = true, hasArtwork: Bool = false,
        skipEnabled: Bool = true, elapsed: Double = 10, at: Date? = nil
    ) -> NowPlayingPublication {
        NowPlayingPublication(
            songId: songId, title: title, artist: artist, album: album, duration: duration,
            isPlaying: isPlaying, hasArtwork: hasArtwork, skipEnabled: skipEnabled,
            elapsed: elapsed, publishedAt: at ?? t0)
    }

    private func should(_ prev: NowPlayingPublication?, _ next: NowPlayingPublication, after: TimeInterval = 0.25) -> Bool {
        NowPlayingPublication.shouldPublish(previous: prev, next: next, now: t0.addingTimeInterval(after))
    }

    func testPublishesWhenNothingWasPublishedYet() {
        XCTAssertTrue(should(nil, publication()))
    }

    func testSkipsWhenOnlyExpectedElapsedAdvanceWhilePlaying() {
        XCTAssertFalse(should(publication(), publication(elapsed: 10.25)))
    }

    func testSkipsWhenPausedAndElapsedUnchanged() {
        let paused = publication(isPlaying: false)
        XCTAssertFalse(should(paused, paused))
    }

    func testPublishesOnPlayingFlip() {
        XCTAssertTrue(should(publication(), publication(isPlaying: false)))
    }

    func testPublishesOnMetadataChanges() {
        let base = publication()
        XCTAssertTrue(should(base, publication(songId: "b")))
        XCTAssertTrue(should(base, publication(title: "U")))
        XCTAssertTrue(should(base, publication(artist: "B")))
        XCTAssertTrue(should(base, publication(album: "Bl")))
        XCTAssertTrue(should(base, publication(duration: 201)))
        XCTAssertTrue(should(base, publication(hasArtwork: true)))
        XCTAssertTrue(should(base, publication(skipEnabled: false)))
    }

    func testPublishesOnSeekJump() {
        XCTAssertTrue(should(publication(), publication(elapsed: 15.25)))
    }

    func testPublishesWhenPausedElapsedMoves() {
        XCTAssertTrue(should(publication(isPlaying: false), publication(isPlaying: false, elapsed: 12)))
    }

    func testPublishesWhenPlayingElapsedStalls() {
        // Expected 10 + 5 = 15 after 5 s, but the position stayed at 10 (e.g. buffering).
        XCTAssertTrue(should(publication(), publication(elapsed: 10), after: 5))
    }
}

