import XCTest
@testable import UX_Music_TV

/// Pure-logic tests for the relay playback failure-recovery state machine (user report: "relay
/// failure wedges ALL playback"). `TVRelayPlaybackReducer` is the seam that decides local
/// (`MusicPlayerService`) playback usability independent of `AVPlayer` side effects, so this is
/// tested without touching `TVRelayPlaybackController`/`AVFoundation` at all. See
/// `progress/tvos-relay-reception.md`.
final class TVRelayPlaybackReducerTests: XCTestCase {
    func testStartTransitionsIdleToPlaying() {
        let next = TVRelayPlaybackReducer.reduce(.idle, event: .start)
        XCTAssertEqual(next, .playing)
    }

    func testFailTransitionsPlayingToFailedWithReason() {
        let next = TVRelayPlaybackReducer.reduce(.playing, event: .fail(reason: "timeout"))
        XCTAssertEqual(next, .failed(reason: "timeout"))
    }

    func testExitTransitionsAnyStateToIdle() {
        XCTAssertEqual(TVRelayPlaybackReducer.reduce(.playing, event: .exit), .idle)
        XCTAssertEqual(TVRelayPlaybackReducer.reduce(.failed(reason: "x"), event: .exit), .idle)
        XCTAssertEqual(TVRelayPlaybackReducer.reduce(.idle, event: .exit), .idle)
    }

    /// The critical invariant behind the bug fix: local playback must be usable in every state
    /// except while the relay is actively `.playing` (browse already stops local playback before
    /// starting the relay). Crucially, `.failed` is player-usable — a relay failure must never
    /// leave local playback blocked.
    func testLocalPlaybackUsableInIdleAndFailedButNotWhilePlaying() {
        XCTAssertTrue(TVRelayPlaybackReducer.isLocalPlaybackUsable(.idle))
        XCTAssertTrue(TVRelayPlaybackReducer.isLocalPlaybackUsable(.failed(reason: "any")))
        XCTAssertFalse(TVRelayPlaybackReducer.isLocalPlaybackUsable(.playing))
    }

    func testFullFailureRecoveryLifecycleEndsPlayerUsable() {
        var state = TVRelayPlaybackState.idle
        state = TVRelayPlaybackReducer.reduce(state, event: .start)
        XCTAssertFalse(TVRelayPlaybackReducer.isLocalPlaybackUsable(state))
        state = TVRelayPlaybackReducer.reduce(state, event: .fail(reason: "AVPlayerItem failed"))
        XCTAssertTrue(TVRelayPlaybackReducer.isLocalPlaybackUsable(state))
        state = TVRelayPlaybackReducer.reduce(state, event: .exit)
        XCTAssertTrue(TVRelayPlaybackReducer.isLocalPlaybackUsable(state))
        XCTAssertEqual(state, .idle)
    }
}
