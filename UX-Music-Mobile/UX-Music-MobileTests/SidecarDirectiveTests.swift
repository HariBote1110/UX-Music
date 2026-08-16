import UIKit
import XCTest
@testable import UX_Music_Mobile

final class SidecarDirectiveTests: XCTestCase {

    // MARK: - SidecarOrientationPolicy

    func testMaskIsLandscapeWhenSidecarPresented() {
        XCTAssertEqual(
            SidecarOrientationPolicy.mask(sidecarPresented: true, defaultMask: .allButUpsideDown),
            .landscape
        )
    }

    func testMaskIsDefaultWhenSidecarNotPresented() {
        XCTAssertEqual(
            SidecarOrientationPolicy.mask(sidecarPresented: false, defaultMask: .allButUpsideDown),
            .allButUpsideDown
        )
    }

    // MARK: - SidecarChromeVisibilityPolicy

    func testChromeVisibleImmediatelyAfterInteraction() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(SidecarChromeVisibilityPolicy.isVisible(lastInteraction: now, now: now))
    }

    func testChromeVisibleJustBeforeIdleThreshold() {
        let last = Date(timeIntervalSince1970: 1000)
        let now = last.addingTimeInterval(4.9)
        XCTAssertTrue(SidecarChromeVisibilityPolicy.isVisible(lastInteraction: last, now: now))
    }

    func testChromeHiddenAtIdleThreshold() {
        let last = Date(timeIntervalSince1970: 1000)
        let now = last.addingTimeInterval(5)
        XCTAssertFalse(SidecarChromeVisibilityPolicy.isVisible(lastInteraction: last, now: now))
    }

    func testChromeHiddenWellPastIdleThreshold() {
        let last = Date(timeIntervalSince1970: 1000)
        let now = last.addingTimeInterval(60)
        XCTAssertFalse(SidecarChromeVisibilityPolicy.isVisible(lastInteraction: last, now: now))
    }

    func testChromeVisibleAgainWithCustomThreshold() {
        let last = Date(timeIntervalSince1970: 1000)
        let now = last.addingTimeInterval(2)
        XCTAssertFalse(SidecarChromeVisibilityPolicy.isVisible(lastInteraction: last, now: now, idleThreshold: 1))
    }

    // MARK: - SidecarDirective.parse

    func testParseActiveWithSongIdAndArtworkId() {
        let state: [String: Any] = [
            "sidecar": ["active": true],
            "songId": "song-1",
            "artworkId": "artwork-1",
        ]
        let directive = SidecarDirective.parse(from: state)
        XCTAssertEqual(directive, SidecarDirective(active: true, songId: "song-1", artworkId: "artwork-1"))
    }

    func testParseActiveWithoutSongIdOrArtworkId() {
        let state: [String: Any] = ["sidecar": ["active": true]]
        let directive = SidecarDirective.parse(from: state)
        XCTAssertEqual(directive, SidecarDirective(active: true, songId: nil, artworkId: nil))
    }

    func testParseActiveWithEmptyStringIdsTreatsThemAsAbsent() {
        let state: [String: Any] = [
            "sidecar": ["active": true],
            "songId": "",
            "artworkId": "",
        ]
        let directive = SidecarDirective.parse(from: state)
        XCTAssertEqual(directive, SidecarDirective(active: true, songId: nil, artworkId: nil))
    }

    func testParseExplicitlyInactive() {
        let state: [String: Any] = ["sidecar": ["active": false], "songId": "song-1"]
        XCTAssertEqual(SidecarDirective.parse(from: state), .inactive)
    }

    func testParseMissingSidecarKey() {
        let state: [String: Any] = ["title": "Some Song"]
        XCTAssertEqual(SidecarDirective.parse(from: state), .inactive)
    }

    func testParseSidecarNotADictionary() {
        let state: [String: Any] = ["sidecar": "not-a-dict"]
        XCTAssertEqual(SidecarDirective.parse(from: state), .inactive)
    }

    func testParseActiveNotABool() {
        let state: [String: Any] = ["sidecar": ["active": "yes"]]
        XCTAssertEqual(SidecarDirective.parse(from: state), .inactive)
    }

    func testParseMissingActiveKey() {
        let state: [String: Any] = ["sidecar": [:]]
        XCTAssertEqual(SidecarDirective.parse(from: state), .inactive)
    }

    func testParseEmptyState() {
        XCTAssertEqual(SidecarDirective.parse(from: [:]), .inactive)
    }

    // MARK: - SidecarProgressInterpolation

    func testInterpolationAdvancesWhilePlaying() {
        let start = Date(timeIntervalSince1970: 1000)
        let now = start.addingTimeInterval(2.5)
        let result = SidecarProgressInterpolation.interpolatedPosition(
            position: 10, timestamp: start, playing: true, now: now, duration: 200
        )
        XCTAssertEqual(result, 12.5, accuracy: 0.001)
    }

    func testInterpolationHoldsStillWhilePaused() {
        let start = Date(timeIntervalSince1970: 1000)
        let now = start.addingTimeInterval(5)
        let result = SidecarProgressInterpolation.interpolatedPosition(
            position: 10, timestamp: start, playing: false, now: now, duration: 200
        )
        XCTAssertEqual(result, 10, accuracy: 0.001)
    }

    func testInterpolationClampsToDuration() {
        let start = Date(timeIntervalSince1970: 1000)
        let now = start.addingTimeInterval(500)
        let result = SidecarProgressInterpolation.interpolatedPosition(
            position: 10, timestamp: start, playing: true, now: now, duration: 200
        )
        XCTAssertEqual(result, 200, accuracy: 0.001)
    }

    func testInterpolationClampsToZeroWhenNowPrecedesTimestamp() {
        let start = Date(timeIntervalSince1970: 1000)
        let now = start.addingTimeInterval(-5)
        let result = SidecarProgressInterpolation.interpolatedPosition(
            position: 10, timestamp: start, playing: true, now: now, duration: 200
        )
        XCTAssertEqual(result, 10, accuracy: 0.001)
    }

    func testInterpolationWithoutDurationStillClampsToZero() {
        let start = Date(timeIntervalSince1970: 1000)
        let now = start.addingTimeInterval(-100)
        let result = SidecarProgressInterpolation.interpolatedPosition(
            position: 0, timestamp: start, playing: true, now: now, duration: 0
        )
        XCTAssertEqual(result, 0, accuracy: 0.001)
    }

    // MARK: - SidecarPresentationPolicy

    func testShouldPresentWhenActiveAndNotDismissed() {
        XCTAssertTrue(SidecarPresentationPolicy.shouldPresent(active: true, locallyDismissed: false))
    }

    func testShouldNotPresentWhenInactive() {
        XCTAssertFalse(SidecarPresentationPolicy.shouldPresent(active: false, locallyDismissed: false))
    }

    func testShouldNotPresentWhenLocallyDismissed() {
        XCTAssertFalse(SidecarPresentationPolicy.shouldPresent(active: true, locallyDismissed: true))
    }

    func testShouldClearDismissalOnFalseToTrueTransition() {
        XCTAssertTrue(SidecarPresentationPolicy.shouldClearDismissal(previousActive: false, newActive: true))
    }

    func testShouldNotClearDismissalWhenAlreadyActive() {
        XCTAssertFalse(SidecarPresentationPolicy.shouldClearDismissal(previousActive: true, newActive: true))
    }

    func testShouldNotClearDismissalOnTrueToFalseTransition() {
        XCTAssertFalse(SidecarPresentationPolicy.shouldClearDismissal(previousActive: true, newActive: false))
    }

    // MARK: - SidecarMetadataSnapshot

    /// Guards `AppModel`'s sidecar poller: title/artist/album/artwork/duration/playing rarely
    /// change between 2s ticks (the desktop reports the same track dozens of times while it
    /// plays), so writing them unconditionally on every tick fires an `@Observable` invalidation
    /// for every view reading them even though nothing actually changed. `position`/`timestamp`
    /// are deliberately excluded — those must be written every successful tick regardless of
    /// value so `SidecarProgressInterpolation` keeps a fresh wall-clock anchor.
    func testMetadataSnapshotEqualWhenAllFieldsMatch() {
        let a = SidecarMetadataSnapshot(songId: "s1", artworkId: "a1", title: "T", artist: "Ar", album: "Al", duration: 200, playing: true)
        let b = SidecarMetadataSnapshot(songId: "s1", artworkId: "a1", title: "T", artist: "Ar", album: "Al", duration: 200, playing: true)
        XCTAssertEqual(a, b)
    }

    func testMetadataSnapshotDiffersWhenTitleChanges() {
        let a = SidecarMetadataSnapshot(songId: "s1", artworkId: "a1", title: "T", artist: "Ar", album: "Al", duration: 200, playing: true)
        let b = SidecarMetadataSnapshot(songId: "s1", artworkId: "a1", title: "Different", artist: "Ar", album: "Al", duration: 200, playing: true)
        XCTAssertNotEqual(a, b)
    }

    func testMetadataSnapshotDiffersWhenPlayingChanges() {
        let a = SidecarMetadataSnapshot(songId: "s1", artworkId: "a1", title: "T", artist: "Ar", album: "Al", duration: 200, playing: true)
        let b = SidecarMetadataSnapshot(songId: "s1", artworkId: "a1", title: "T", artist: "Ar", album: "Al", duration: 200, playing: false)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - SidecarActiveLineUpdatePolicy

    /// Guards `SidecarSyncedLyricsList`'s `TimelineView(.periodic(from:by: 0.2))` tick: recomputing
    /// the interpolated position at 5Hz is cheap, but writing it to `@State` unconditionally forces
    /// the whole lyric `ForEach` to re-diff 5x/sec for as long as the sidecar screen is on screen.
    /// Only an actual change of active line should trigger that redraw.
    func testActiveLineUpdatePolicySameIndexDoesNotUpdate() {
        XCTAssertFalse(SidecarActiveLineUpdatePolicy.shouldUpdate(currentIndex: 3, newIndex: 3))
    }

    func testActiveLineUpdatePolicyDifferentIndexUpdates() {
        XCTAssertTrue(SidecarActiveLineUpdatePolicy.shouldUpdate(currentIndex: 3, newIndex: 4))
    }

    // MARK: - SidecarLyricsDisplay

    /// Mirrors Desktop's `fsDisplayText` (`fullscreen-view.ts:14-16`): a literal marker line such
    /// as `[間奏]` must render as blank space, not the bracketed text itself.
    func testDisplayTextBlanksLiteralInterludeMarkers() {
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "[間奏]"), " ")
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "[interlude]"), " ")
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "(interlude)"), " ")
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "[INTERLUDE]"), " ")
    }

    func testDisplayTextBlanksEmptyOrWhitespaceLines() {
        XCTAssertEqual(SidecarLyricsDisplay.text(for: ""), " ")
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "   "), " ")
    }

    /// Must not over-filter real lyrics that merely start with a bracket.
    func testDisplayTextKeepsRealLyricsThatStartWithBrackets() {
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "[Chorus] hello"), "[Chorus] hello")
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "(laughs) that's funny"), "(laughs) that's funny")
    }

    func testDisplayTextKeepsOrdinaryLyrics() {
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "Hello there"), "Hello there")
    }
}
