import XCTest
@testable import UX_Music_TV

/// TDD (Red): the tvOS lyrics pane is being upgraded from a hard-coded 3-line window to the same
/// Desktop-parity "stage" the Sidecar screen renders (`progress/sidecar-lyrics-fade-and-bilingual.md`):
/// interlude markers blanked, 和訳 (translation) sublines, per-line cumulative motion layout.
/// These tests pin the shared `Core/LyricsStageKit.swift` behaviour *from the TV target*, i.e. they
/// also assert that the file is actually a member of `UX-Music-TV` rather than silently reimplemented.
final class TVLyricsStageTests: XCTestCase {
    // MARK: - Interlude markers (Desktop `fsDisplayText` parity)

    func test_interludeMarkerRendersAsBlank() {
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "[間奏]"), " ")
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "(interlude)"), " ")
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "   "), " ")
    }

    func test_realLyricStartingWithBracketIsKept() {
        XCTAssertEqual(SidecarLyricsDisplay.text(for: "[Chorus] hello"), "[Chorus] hello")
    }

    // MARK: - Bilingual pairing from `/v1/remote/lyrics`

    func test_translationPairedByTimestamp_forLrcFormat() {
        let primary = LRCParser.parseTimedLines("[00:01.00]hello\n[00:05.00]world")
        let merged = SidecarLyricsTranslationMerge.merge(
            primary: primary,
            translationContent: "[00:05.00]せかい\n[00:01.00]こんにちは",
            translationFormat: "lrc"
        )
        XCTAssertEqual(merged.map(\.translation), ["こんにちは", "せかい"])
    }

    func test_noTranslationContent_yieldsNilTranslations() {
        let primary = LRCParser.parseTimedLines("[00:01.00]hello")
        let merged = SidecarLyricsTranslationMerge.merge(primary: primary, translationContent: nil, translationFormat: nil)
        XCTAssertEqual(merged.count, 1)
        XCTAssertNil(merged[0].translation)
    }

    // MARK: - Active line / motion layout

    /// Desktop's `findLyricsIndex` rule: nothing highlighted during an instrumental intro.
    func test_noActiveLineBeforeFirstTimestamp() {
        let lines = LRCParser.parseTimedLines("[00:10.00]first")
        XCTAssertEqual(SidecarLyricsMotionPolicy.activeIndex(in: lines, at: 2), -1)
    }

    func test_activeLineIsLastLineAtOrBeforeNow() {
        let lines = LRCParser.parseTimedLines("[00:00.00]a\n[00:10.00]b\n[00:20.00]c")
        XCTAssertEqual(SidecarLyricsMotionPolicy.activeIndex(in: lines, at: 15), 1)
    }

    /// The active line is anchored 35% down the pane and its neighbours stack around it — the TV
    /// stage passes a wider `interBlockGap` than Desktop's 16pt so 10-foot type doesn't crowd.
    func test_topsAnchorActiveLineAndHonourCustomGap() {
        let tops = SidecarLyricsLayout.tops(
            heights: [50, 50, 50],
            baseIndex: 1,
            paneHeight: 1000,
            interBlockGap: TVLyricsStageMetrics.interBlockGap
        )
        XCTAssertEqual(tops[1], 350, accuracy: 0.0001)
        XCTAssertEqual(tops[2], 350 + 50 + TVLyricsStageMetrics.interBlockGap, accuracy: 0.0001)
        XCTAssertEqual(tops[0], 350 - 50 - TVLyricsStageMetrics.interBlockGap, accuracy: 0.0001)
    }

    /// 10-foot legibility: the TV stage must be typeset considerably larger than the Sidecar's
    /// 28pt/20pt phone-and-tablet pairing, with the 和訳 subline still smaller than its primary.
    func test_tvTypeIsScaledForTenFootViewing() {
        XCTAssertGreaterThan(TVLyricsStageMetrics.primaryFontSize, 28)
        XCTAssertLessThan(TVLyricsStageMetrics.translationFontSize, TVLyricsStageMetrics.primaryFontSize)
    }
}
