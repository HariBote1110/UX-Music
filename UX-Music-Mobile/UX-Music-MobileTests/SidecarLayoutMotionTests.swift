import UIKit
import XCTest
@testable import UX_Music_Mobile

/// Covers `SidecarArtworkLayout` (square sizing, no letterboxing) and `SidecarLyricsMotionPolicy`
/// (Desktop-fullscreen-matched scroll/stagger parameters for `SidecarSyncedLyricsList`).
final class SidecarLayoutMotionTests: XCTestCase {

    // MARK: - SidecarArtworkLayout

    /// A wide column (landscape left pane) should be capped by the shorter of the two dimensions,
    /// after margins, so the artwork renders as an exact square with no leftover strip.
    func testArtworkSideCappedByShorterDimensionWide() {
        let side = SidecarArtworkLayout.squareSide(columnWidth: 500, columnHeight: 300, margin: 0, maxSide: 1000)
        XCTAssertEqual(side, 300)
    }

    /// A tall column should be capped by width instead.
    func testArtworkSideCappedByShorterDimensionTall() {
        let side = SidecarArtworkLayout.squareSide(columnWidth: 300, columnHeight: 900, margin: 0, maxSide: 1000)
        XCTAssertEqual(side, 300)
    }

    func testArtworkSideSubtractsMarginFromBothDimensions() {
        let side = SidecarArtworkLayout.squareSide(columnWidth: 500, columnHeight: 500, margin: 20, maxSide: 1000)
        // Margin is applied once per side of the square (i.e. subtracted from the raw min directly).
        XCTAssertEqual(side, 480)
    }

    func testArtworkSideNeverExceedsMaxSide() {
        let side = SidecarArtworkLayout.squareSide(columnWidth: 900, columnHeight: 900, margin: 0, maxSide: 420)
        XCTAssertEqual(side, 420)
    }

    func testArtworkSideNeverNegative() {
        let side = SidecarArtworkLayout.squareSide(columnWidth: 10, columnHeight: 10, margin: 40, maxSide: 1000)
        XCTAssertEqual(side, 0)
    }

    // MARK: - SidecarLyricsMotionPolicy

    /// Ported from Desktop's `applyLyricsMotion` (`src/renderer/js/features/fullscreen-view.ts`):
    /// `MOTION_DELAY_STEP_MS = 40` staggers each line's transition start by its distance from the
    /// active line, producing the ripple/cascade feel instead of every line moving in lockstep.
    func testStaggerDelayScalesWithDistance() {
        XCTAssertEqual(SidecarLyricsMotionPolicy.staggerDelay(forDistance: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(SidecarLyricsMotionPolicy.staggerDelay(forDistance: 3), 0.12, accuracy: 0.0001)
    }

    /// Distance is always given as `abs(index - active)` by callers, but the policy itself should
    /// not produce a negative delay even if handed a negative value defensively.
    func testStaggerDelayClampsNegativeDistanceToZero() {
        XCTAssertEqual(SidecarLyricsMotionPolicy.staggerDelay(forDistance: -2), 0, accuracy: 0.0001)
    }

    /// Ported from Desktop's `MOTION_DURATION_MS = 800`.
    func testMotionDurationMatchesDesktop() {
        XCTAssertEqual(SidecarLyricsMotionPolicy.duration, 0.8, accuracy: 0.0001)
    }

    /// Ported from Desktop's `ANCHOR_RATIO = 0.35` (the active line sits 35% down the lyrics pane,
    /// not dead centre) and the 1.091x active-line scale (`transform: scale(1.091)` in
    /// `components.css`'s `.fs-lyrics-inner.fs-lrc p.active`).
    func testScrollAnchorMatchesDesktopRatio() {
        XCTAssertEqual(SidecarLyricsMotionPolicy.scrollAnchor.y, 0.35, accuracy: 0.0001)
        XCTAssertEqual(SidecarLyricsMotionPolicy.scrollAnchor.x, 0.5, accuracy: 0.0001)
    }

    func testActiveLineScaleMatchesDesktop() {
        XCTAssertEqual(SidecarLyricsMotionPolicy.activeLineScale, 1.091, accuracy: 0.0001)
    }

    // MARK: - SidecarBackgroundGradient

    /// Ported from `color-mix(in srgb, var(--fs-bg-1) 30%, #0e0e1a)` (`components.css:1770-1771`):
    /// a pure red swatch mixed 30% into `#0e0e1a` should land at `0.3*1 + 0.7*(14/255)` etc.
    func testMixedStopBlendsSwatchTowardsNearBlackBase() {
        let mixed = SidecarBackgroundGradient.mixedStop(from: (1, 0, 0))
        XCTAssertEqual(mixed.0, 0.3 * 1 + 0.7 * (14.0 / 255.0), accuracy: 0.0001)
        XCTAssertEqual(mixed.1, 0.3 * 0 + 0.7 * (14.0 / 255.0), accuracy: 0.0001)
        XCTAssertEqual(mixed.2, 0.3 * 0 + 0.7 * (26.0 / 255.0), accuracy: 0.0001)
    }

    func testMixedStopAtZeroRatioReturnsBase() {
        let mixed = SidecarBackgroundGradient.mixedStop(from: (1, 1, 1), ratio: 0)
        XCTAssertEqual(mixed.0, SidecarBackgroundGradient.mixBase.0, accuracy: 0.0001)
        XCTAssertEqual(mixed.1, SidecarBackgroundGradient.mixBase.1, accuracy: 0.0001)
        XCTAssertEqual(mixed.2, SidecarBackgroundGradient.mixBase.2, accuracy: 0.0001)
    }

    func testMixedStopAtFullRatioReturnsSwatchUnchanged() {
        let mixed = SidecarBackgroundGradient.mixedStop(from: (0.2, 0.4, 0.6), ratio: 1)
        XCTAssertEqual(mixed.0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(mixed.1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(mixed.2, 0.6, accuracy: 0.0001)
    }

    func testMixedStopClampsOutOfRangeRatio() {
        let over = SidecarBackgroundGradient.mixedStop(from: (0.5, 0.5, 0.5), ratio: 2)
        let under = SidecarBackgroundGradient.mixedStop(from: (0.5, 0.5, 0.5), ratio: -1)
        XCTAssertEqual(over.0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(under.0, SidecarBackgroundGradient.mixBase.0, accuracy: 0.0001)
    }

    func testDefaultMixRatioAndDurationMatchDesktop() {
        XCTAssertEqual(SidecarBackgroundGradient.mixRatio, 0.30, accuracy: 0.0001)
        XCTAssertEqual(SidecarBackgroundGradient.transitionDuration, 1.2, accuracy: 0.0001)
    }

    // MARK: - SidecarLyricsLayout

    /// Ported from Desktop's `applyLyricsMotion` (`fullscreen-view.ts:392-426`): the base (active,
    /// or index 0 while nothing is active yet) line sits at `paneHeight * ANCHOR_RATIO`, and every
    /// other line stacks above/below it via a running sum of `height + INTER_BLOCK_GAP (16)`.
    func testTopsAnchorsBaseIndexAtAnchorRatio() {
        let tops = SidecarLyricsLayout.tops(heights: [40, 40, 40], baseIndex: 1, paneHeight: 200)
        XCTAssertEqual(tops[1], 70, accuracy: 0.001) // 200 * 0.35
    }

    func testTopsStackForwardWithGap() {
        let tops = SidecarLyricsLayout.tops(heights: [40, 50, 60], baseIndex: 0, paneHeight: 200)
        XCTAssertEqual(tops[0], 70, accuracy: 0.001)
        XCTAssertEqual(tops[1], 70 + 40 + 16, accuracy: 0.001)
        XCTAssertEqual(tops[2], 70 + 40 + 16 + 50 + 16, accuracy: 0.001)
    }

    func testTopsStackBackwardWithGap() {
        let tops = SidecarLyricsLayout.tops(heights: [40, 50, 60], baseIndex: 2, paneHeight: 200)
        XCTAssertEqual(tops[2], 70, accuracy: 0.001)
        XCTAssertEqual(tops[1], 70 - 50 - 16, accuracy: 0.001)
        XCTAssertEqual(tops[0], 70 - 50 - 16 - 40 - 16, accuracy: 0.001)
    }

    func testTopsClampsBaseIndexIntoRange() {
        let tops = SidecarLyricsLayout.tops(heights: [40, 40], baseIndex: 99, paneHeight: 200)
        XCTAssertEqual(tops[1], 70, accuracy: 0.001)
    }

    func testTopsEmptyHeightsReturnsEmpty() {
        XCTAssertEqual(SidecarLyricsLayout.tops(heights: [], baseIndex: 0, paneHeight: 200), [])
    }

    func testInterBlockGapAndAnchorRatioMatchDesktop() {
        XCTAssertEqual(SidecarLyricsLayout.interBlockGap, 16, accuracy: 0.0001)
        XCTAssertEqual(SidecarLyricsLayout.anchorRatio, 0.35, accuracy: 0.0001)
    }

    // MARK: - SidecarLyricsMotionPolicy.activeIndex (Desktop `findLyricsIndex` parity)

    /// Ported from Desktop's `findLyricsIndex` (`fullscreen-view.ts:366-390`): before the first
    /// line's timestamp, NO line is active (`-1`) — unlike `LRCParser.activeLineIndex`, which other
    /// screens intentionally clamp to `0` for a different UX. The sidecar must not highlight line 0
    /// during an instrumental intro.
    func testActiveIndexReturnsMinusOneBeforeFirstLine() {
        let lines = [LRCParser.TimedLine(id: 1, startTime: 10, text: "a"), LRCParser.TimedLine(id: 2, startTime: 20, text: "b")]
        XCTAssertEqual(SidecarLyricsMotionPolicy.activeIndex(in: lines, at: 5), -1)
    }

    func testActiveIndexReturnsLastLineAtOrAfterEnd() {
        let lines = [LRCParser.TimedLine(id: 1, startTime: 10, text: "a"), LRCParser.TimedLine(id: 2, startTime: 20, text: "b")]
        XCTAssertEqual(SidecarLyricsMotionPolicy.activeIndex(in: lines, at: 999), 1)
    }

    func testActiveIndexTracksLastLineAtOrBeforeTime() {
        let lines = [LRCParser.TimedLine(id: 1, startTime: 10, text: "a"), LRCParser.TimedLine(id: 2, startTime: 20, text: "b"), LRCParser.TimedLine(id: 3, startTime: 30, text: "c")]
        XCTAssertEqual(SidecarLyricsMotionPolicy.activeIndex(in: lines, at: 20), 1)
        XCTAssertEqual(SidecarLyricsMotionPolicy.activeIndex(in: lines, at: 25), 1)
    }

    func testActiveIndexEmptyLinesReturnsMinusOne() {
        let lines: [LRCParser.TimedLine] = []
        XCTAssertEqual(SidecarLyricsMotionPolicy.activeIndex(in: lines, at: 5), -1)
    }

    // MARK: - SidecarLyricsTranslationMerge

    func testTranslationMergeReturnsNilTranslationsWhenContentAbsent() {
        let primary = [LRCParser.TimedLine(id: 1, startTime: 1, text: "hi")]
        let merged = SidecarLyricsTranslationMerge.merge(primary: primary, translationContent: nil, translationFormat: nil)
        XCTAssertEqual(merged, [TranslatedTimedLine(id: 1, startTime: 1, text: "hi", translation: nil)])
    }

    func testTranslationMergeReturnsNilTranslationsWhenContentBlank() {
        let primary = [LRCParser.TimedLine(id: 1, startTime: 1, text: "hi")]
        let merged = SidecarLyricsTranslationMerge.merge(primary: primary, translationContent: "   \n", translationFormat: "txt")
        XCTAssertEqual(merged, [TranslatedTimedLine(id: 1, startTime: 1, text: "hi", translation: nil)])
    }

    func testTranslationMergeUsesTimestampPairingForLRCFormat() {
        let primary = [
            LRCParser.TimedLine(id: 1, startTime: 1, text: "hi"),
            LRCParser.TimedLine(id: 2, startTime: 5, text: "there"),
        ]
        let translationContent = "[00:05.00]やあ\n[00:01.00]こんにちは"
        let merged = SidecarLyricsTranslationMerge.merge(primary: primary, translationContent: translationContent, translationFormat: "lrc")
        XCTAssertEqual(merged.map(\.translation), ["こんにちは", "やあ"])
    }

    func testTranslationMergeUsesPositionalPairingForTxtFormat() {
        let primary = [
            LRCParser.TimedLine(id: 1, startTime: 1, text: "hi"),
            LRCParser.TimedLine(id: 2, startTime: 5, text: "there"),
        ]
        let translationContent = "こんにちは\nやあ"
        let merged = SidecarLyricsTranslationMerge.merge(primary: primary, translationContent: translationContent, translationFormat: "txt")
        XCTAssertEqual(merged.map(\.translation), ["こんにちは", "やあ"])
    }

    func testTranslationMergeTreatsMissingFormatAsPositional() {
        let primary = [LRCParser.TimedLine(id: 1, startTime: 1, text: "hi")]
        let merged = SidecarLyricsTranslationMerge.merge(primary: primary, translationContent: "こんにちは", translationFormat: nil)
        XCTAssertEqual(merged.map(\.translation), ["こんにちは"])
    }

    func testTranslationMergeNeverTranslatesInterludeLines() {
        let primary = [LRCParser.TimedLine(id: 1, startTime: 1, text: "")]
        let merged = SidecarLyricsTranslationMerge.merge(primary: primary, translationContent: "should not attach", translationFormat: "txt")
        XCTAssertEqual(merged.map(\.translation), [nil])
    }
}
