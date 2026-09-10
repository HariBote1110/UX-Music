import XCTest
@testable import UX_Music_Mobile

/// Pure-logic tests for the Apple-Music-style synced lyrics screen: seek target
/// resolution and the auto-scroll pause/resume window.
///
/// The container-offset line layout, the per-distance stagger delay, the active-line index
/// (Desktop `findLyricsIndex` parity) and the soft edge fade were all local re-implementations
/// here; the synced-lyrics view now renders from the shared `Core/LyricsStageKit.swift`
/// primitives (`SidecarLyricsLayout.tops`, `SidecarLyricsMotionPolicy`, `SidecarLyricsEdgeFade`),
/// which are covered by `SidecarLayoutMotionTests`. Only the mobile-only helpers stay here.
final class NowPlayingLyricsLogicTests: XCTestCase {
    // MARK: - Seek target

    func testLyricsSeekTimeForwardsLineStartTime() {
        let line = LRCParser.TimedLine(id: 3, startTime: 42.5, text: "Hello")
        XCTAssertEqual(nowPlayingLyricsSeekTime(for: line), 42.5, accuracy: 0.0001)
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
