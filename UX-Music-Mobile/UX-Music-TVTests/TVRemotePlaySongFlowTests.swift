import XCTest
@testable import UX_Music_TV

/// Pure-logic tests for the "select a YouTube-sourced song on the TV → play it via the PC and
/// auto-join the LAN relay" feature (`progress/tvos-relay-reception.md` 追記). Two seams are
/// covered without any networking/AVFoundation involved:
/// - `TVSongPlaybackRouting.route(for:)` — the selection-routing decision (local vs. via-PC).
/// - `TVRemotePlaySongReducer` — the wait-for-relay state machine driving the "PC経由で再生中"
///   flow (send `play-song` → wait for `relay.active` → join, or fail/timeout back to usable).
final class TVRemotePlaySongFlowTests: XCTestCase {
    // MARK: - Routing

    func testLocalSongRoutesToLocalPlayback() {
        let song = Song(id: "1", path: "/a.mp3", sourceType: .local)
        XCTAssertEqual(TVSongPlaybackRouting.route(for: song), .local)
    }

    /// Most YouTube-sourced songs are downloaded, so the host serves their audio locally — they
    /// route the same as any local song (`progress/tvos-relay-reception.md` 追記 — "route by file
    /// availability, not source").
    func testDownloadedYouTubeSongRoutesToLocalPlayback() {
        let song = Song(id: "2", path: "", sourceType: .youtube, hasLocalAudio: true)
        XCTAssertEqual(TVSongPlaybackRouting.route(for: song), .local)
    }

    /// Only a song the host genuinely cannot serve audio for (embed/stream-only entry) routes via
    /// the PC's own playback + LAN relay.
    func testYouTubeSongWithoutLocalAudioRoutesViaPC() {
        let song = Song(id: "3", path: "", sourceType: .youtube, hasLocalAudio: false)
        XCTAssertEqual(TVSongPlaybackRouting.route(for: song), .viaPC)
    }

    /// `hasLocalAudio` is additive — an older desktop (or a not-yet-updated in-flight response)
    /// omitting the key entirely must default to `.local`, never silently regress a YouTube song
    /// that used to always route via PC into being treated as unavailable.
    func testYouTubeSongWithMissingHasLocalAudioDefaultsToLocalPlayback() {
        let song = Song(id: "4", path: "", sourceType: .youtube, hasLocalAudio: nil)
        XCTAssertEqual(TVSongPlaybackRouting.route(for: song), .local)
    }

    // MARK: - Reducer

    func testStartTransitionsIdleToSending() {
        let next = TVRemotePlaySongReducer.reduce(.idle, event: .start)
        XCTAssertEqual(next, .sending)
    }

    func testSendSucceededTransitionsSendingToWaitingForRelay() {
        let next = TVRemotePlaySongReducer.reduce(.sending, event: .sendSucceeded)
        XCTAssertEqual(next, .waitingForRelay)
    }

    func testSendFailedTransitionsSendingToFailedWithReason() {
        let next = TVRemotePlaySongReducer.reduce(.sending, event: .sendFailed(reason: "gui required"))
        XCTAssertEqual(next, .failed(reason: "gui required"))
    }

    func testRelayActiveTransitionsWaitingForRelayToActive() {
        let next = TVRemotePlaySongReducer.reduce(.waitingForRelay, event: .relayActive)
        XCTAssertEqual(next, .active)
    }

    func testTimedOutTransitionsWaitingForRelayToFailed() {
        let next = TVRemotePlaySongReducer.reduce(.waitingForRelay, event: .timedOut)
        if case .failed = next {} else { XCTFail("expected .failed, got \(next)") }
    }

    func testExitTransitionsAnyStateToIdle() {
        XCTAssertEqual(TVRemotePlaySongReducer.reduce(.active, event: .exit), .idle)
        XCTAssertEqual(TVRemotePlaySongReducer.reduce(.failed(reason: "x"), event: .exit), .idle)
        XCTAssertEqual(TVRemotePlaySongReducer.reduce(.waitingForRelay, event: .exit), .idle)
        XCTAssertEqual(TVRemotePlaySongReducer.reduce(.idle, event: .exit), .idle)
    }

    func testFullHappyPathLifecycle() {
        var state = TVRemotePlaySongState.idle
        state = TVRemotePlaySongReducer.reduce(state, event: .start)
        XCTAssertEqual(state, .sending)
        state = TVRemotePlaySongReducer.reduce(state, event: .sendSucceeded)
        XCTAssertEqual(state, .waitingForRelay)
        state = TVRemotePlaySongReducer.reduce(state, event: .relayActive)
        XCTAssertEqual(state, .active)
    }

    func testFullTimeoutPathEndsFailedThenExitReturnsIdle() {
        var state = TVRemotePlaySongState.idle
        state = TVRemotePlaySongReducer.reduce(state, event: .start)
        state = TVRemotePlaySongReducer.reduce(state, event: .sendSucceeded)
        state = TVRemotePlaySongReducer.reduce(state, event: .timedOut)
        if case .failed = state {} else { XCTFail("expected .failed, got \(state)") }
        state = TVRemotePlaySongReducer.reduce(state, event: .exit)
        XCTAssertEqual(state, .idle)
    }
}
