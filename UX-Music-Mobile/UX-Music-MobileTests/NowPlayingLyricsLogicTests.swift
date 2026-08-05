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
    //
    // Matches UX Music Desktop's `.fs-lyrics-container` mask-image:
    // `linear-gradient(to bottom, transparent 0%, black 8%, black 70%, transparent 100%)`.

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
        // Top fade band is the first 8% of the height (Desktop: transparent 0% -> black 8%).
        let atStart = nowPlayingLyricsFadeOpacity(fraction: 0.0)
        let atMid = nowPlayingLyricsFadeOpacity(fraction: 0.04)
        let atEnd = nowPlayingLyricsFadeOpacity(fraction: 0.08)
        XCTAssertLessThan(atStart, atMid)
        XCTAssertLessThan(atMid, atEnd)
        XCTAssertEqual(atEnd, 1, accuracy: 0.001)
    }

    func testFadeFallsAcrossBottomBand() {
        // Bottom fade band is the last 30% of the height (Desktop: black 70% -> transparent 100%).
        let atStart = nowPlayingLyricsFadeOpacity(fraction: 0.70)
        let atMid = nowPlayingLyricsFadeOpacity(fraction: 0.85)
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

    // MARK: - Container-offset line layout (mirrors Desktop `applyLyricsMotion` in
    // `src/renderer/js/features/fullscreen-view.ts`: anchor the active line at a fixed
    // fraction of the container height, then stack every other line above/below it by
    // cumulative measured height + a fixed inter-line gap).

    func testActiveLineSitsAtAnchor() {
        let offsets = nowPlayingLyricsLineOffsets(heights: [40, 40, 40], activeIndex: 1, anchorY: 100, gap: 16)
        XCTAssertEqual(offsets[1], 100, accuracy: 0.001)
    }

    func testLinesAfterActiveStackDownwardsByHeightPlusGap() {
        let offsets = nowPlayingLyricsLineOffsets(heights: [40, 50, 60], activeIndex: 0, anchorY: 20, gap: 16)
        // offsets[1] = anchor + height[0] + gap
        XCTAssertEqual(offsets[1], 20 + 40 + 16, accuracy: 0.001)
        // offsets[2] = offsets[1] + height[1] + gap
        XCTAssertEqual(offsets[2], 20 + 40 + 16 + 50 + 16, accuracy: 0.001)
    }

    func testLinesBeforeActiveStackUpwardsByHeightPlusGap() {
        let offsets = nowPlayingLyricsLineOffsets(heights: [40, 50, 60], activeIndex: 2, anchorY: 200, gap: 16)
        // offsets[1] = anchor - height[1] - gap
        XCTAssertEqual(offsets[1], 200 - 50 - 16, accuracy: 0.001)
        // offsets[0] = offsets[1] - height[0] - gap
        XCTAssertEqual(offsets[0], 200 - 50 - 16 - 40 - 16, accuracy: 0.001)
    }

    func testOffsetsClampActiveIndexIntoBounds() {
        // No active line yet (-1) behaves like index 0, matching Desktop's `baseIndex`.
        let offsets = nowPlayingLyricsLineOffsets(heights: [40, 40], activeIndex: -1, anchorY: 50, gap: 16)
        XCTAssertEqual(offsets[0], 50, accuracy: 0.001)
    }

    func testOffsetsReturnsEmptyForEmptyHeights() {
        XCTAssertEqual(nowPlayingLyricsLineOffsets(heights: [], activeIndex: 0, anchorY: 50, gap: 16), [])
    }

    func testLineDelayIsProportionalToDistanceFromActive() {
        XCTAssertEqual(nowPlayingLyricsLineDelay(index: 5, activeIndex: 5, stepSeconds: 0.04), 0, accuracy: 0.0001)
        XCTAssertEqual(nowPlayingLyricsLineDelay(index: 7, activeIndex: 5, stepSeconds: 0.04), 0.08, accuracy: 0.0001)
        XCTAssertEqual(nowPlayingLyricsLineDelay(index: 2, activeIndex: 5, stepSeconds: 0.04), 0.12, accuracy: 0.0001)
    }

    func testLineDelayTreatsNoActiveLineAsIndexZero() {
        XCTAssertEqual(nowPlayingLyricsLineDelay(index: 3, activeIndex: -1, stepSeconds: 0.04), 0.12, accuracy: 0.0001)
    }

    // MARK: - Bilingual (和訳) synced lyrics
    //
    // `TranslatedTimedLine` carries the same timing as `LRCParser.TimedLine` and conforms to
    // `LyricsTimedLine`, so the active-line rule is `LRCParser.activeLineIndex` itself — these
    // exercise that shared implementation against the translated line type.

    func testTranslatedSeekTimeForwardsLineStartTime() {
        let line = TranslatedTimedLine(id: 4, startTime: 12.25, text: "Hi", translation: "やあ")
        XCTAssertEqual(nowPlayingLyricsSeekTime(for: line), 12.25, accuracy: 0.0001)
    }

    func testActiveTranslatedLineIndexPicksLastLineAtOrBeforeTime() {
        let lines = [
            TranslatedTimedLine(id: 0, startTime: 0, text: "a", translation: "あ"),
            TranslatedTimedLine(id: 1, startTime: 10, text: "b", translation: nil),
            TranslatedTimedLine(id: 2, startTime: 20, text: "c", translation: "し"),
        ]
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 15), 1)
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 20), 2)
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 999), 2)
    }

    func testActiveTranslatedLineIndexBeforeFirstLineIsZero() {
        let lines = [
            TranslatedTimedLine(id: 0, startTime: 5, text: "a", translation: nil),
            TranslatedTimedLine(id: 1, startTime: 10, text: "b", translation: nil),
        ]
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 0), 0)
    }

    func testActiveTranslatedLineIndexIsZeroForEmptyLines() {
        XCTAssertEqual(LRCParser.activeLineIndex(in: [TranslatedTimedLine](), at: 5), 0)
    }
}
