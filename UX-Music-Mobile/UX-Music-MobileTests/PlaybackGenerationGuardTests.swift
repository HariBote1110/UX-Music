import XCTest
@testable import UX_Music_Mobile

/// Covers `PlaybackGenerationGuard`, the token counter `MusicPlayerService` uses to stop a stale
/// `loadAndPlay` (suspended at `preparePlaybackSessionIfNeeded()` / `Task.yield()`) from mutating
/// shared playback state after a later call has superseded it.
final class PlaybackGenerationGuardTests: XCTestCase {
    func testStartsAtZero() {
        let guardValue = PlaybackGenerationGuard()
        XCTAssertEqual(guardValue.current, 0)
    }

    func testBumpIncrementsMonotonically() {
        var guardValue = PlaybackGenerationGuard()
        XCTAssertEqual(guardValue.bump(), 1)
        XCTAssertEqual(guardValue.bump(), 2)
        XCTAssertEqual(guardValue.bump(), 3)
    }

    func testFreshlyBumpedTokenIsCurrent() {
        var guardValue = PlaybackGenerationGuard()
        let token = guardValue.bump()
        XCTAssertTrue(guardValue.isCurrent(token))
    }

    func testEarlierTokenIsSupersededByALaterBump() {
        var guardValue = PlaybackGenerationGuard()
        let firstToken = guardValue.bump() // e.g. play(A) suspends at an await
        _ = guardValue.bump() // play(B) arrives and overtakes it before A resumes
        XCTAssertFalse(guardValue.isCurrent(firstToken))
    }

    /// Simulates two overlapping `play()` calls: the first token is captured, suspends, and by the
    /// time it would resume a second call has already bumped the guard — so only the second call's
    /// token is current, matching "final state reflects only the most recent invocation".
    func testOnlyTheMostRecentOfSeveralOverlappingTokensIsCurrent() {
        var guardValue = PlaybackGenerationGuard()
        let tokenA = guardValue.bump()
        let tokenB = guardValue.bump()
        let tokenC = guardValue.bump()

        XCTAssertFalse(guardValue.isCurrent(tokenA))
        XCTAssertFalse(guardValue.isCurrent(tokenB))
        XCTAssertTrue(guardValue.isCurrent(tokenC))
    }

    /// Mirrors `stop()` bumping the generation so a stale, already-in-flight `loadAndPlay` cannot
    /// resurrect playback after the user explicitly stopped it.
    func testBumpWithoutIssuingANewTokenInvalidatesThePreviousOne() {
        var guardValue = PlaybackGenerationGuard()
        let token = guardValue.bump() // play() in flight
        guardValue.bump() // stop() invalidates it, no caller holds the new token
        XCTAssertFalse(guardValue.isCurrent(token))
    }
}
