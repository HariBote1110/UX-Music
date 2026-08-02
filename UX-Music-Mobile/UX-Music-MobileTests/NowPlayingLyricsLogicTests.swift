import XCTest
@testable import UX_Music_Mobile

/// Pure-logic tests for the Apple-Music-style synced lyrics screen: seek target
/// resolution, edge fade coefficient, and the auto-scroll pause/resume window.
final class NowPlayingLyricsLogicTests: XCTestCase {
    // MARK: - Seek target

    func testLyricsSeekTimeForwardsLineStartTime() {
        let line = LRCParser.TimedLine(id: 3, startTime: 42.5, text: "Hello")
        XCTAssertEqual(nowPlayingLyricsSeekTime(for: line), 42.5, accuracy: 0.0001)
    }

    // MARK: - Edge fade coefficient

    func testFadeIsZeroAtVeryTop() {
        XCTAssertEqual(nowPlayingLyricsFadeOpacity(fraction: 0), 0, accuracy: 0.001)
    }

    func testFadeIsFullInMiddle() {
        XCTAssertEqual(nowPlayingLyricsFadeOpacity(fraction: 0.5), 1, accuracy: 0.001)
    }

    func testFadeIsZeroAtVeryBottom() {
        XCTAssertEqual(nowPlayingLyricsFadeOpacity(fraction: 1.0), 0, accuracy: 0.001)
    }

    func testFadeRisesAcrossTopBand() {
        // Top fade band is the first 12% of the height.
        let atStart = nowPlayingLyricsFadeOpacity(fraction: 0.0)
        let atMid = nowPlayingLyricsFadeOpacity(fraction: 0.06)
        let atEnd = nowPlayingLyricsFadeOpacity(fraction: 0.12)
        XCTAssertLessThan(atStart, atMid)
        XCTAssertLessThan(atMid, atEnd)
        XCTAssertEqual(atEnd, 1, accuracy: 0.001)
    }

    func testFadeFallsAcrossBottomBand() {
        // Bottom fade band is the last 18% of the height.
        let atStart = nowPlayingLyricsFadeOpacity(fraction: 0.82)
        let atMid = nowPlayingLyricsFadeOpacity(fraction: 0.91)
        let atEnd = nowPlayingLyricsFadeOpacity(fraction: 1.0)
        XCTAssertEqual(atStart, 1, accuracy: 0.001)
        XCTAssertGreaterThan(atMid, atEnd)
        XCTAssertLessThan(atMid, atStart)
    }

    func testFadeClampsOutOfRangeFractions() {
        XCTAssertEqual(nowPlayingLyricsFadeOpacity(fraction: -0.5), 0, accuracy: 0.001)
        XCTAssertEqual(nowPlayingLyricsFadeOpacity(fraction: 1.5), 0, accuracy: 0.001)
    }

    // MARK: - Auto-scroll pause/resume

    func testAutoScrollPausedImmediatelyAfterUserScroll() {
        XCTAssertFalse(nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll: 0))
        XCTAssertFalse(nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll: 2.9))
    }

    func testAutoScrollResumesAfterThreeSeconds() {
        XCTAssertTrue(nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll: 3.0))
        XCTAssertTrue(nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll: 10))
    }

    func testAutoScrollResumesWhenNoUserScrollYet() {
        XCTAssertTrue(nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll: nil))
    }
}
