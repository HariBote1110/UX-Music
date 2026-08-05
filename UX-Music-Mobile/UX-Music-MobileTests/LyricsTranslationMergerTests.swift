import XCTest
@testable import UX_Music_Mobile

final class LyricsTranslationMergerTests: XCTestCase {

    // MARK: - isInterludeText

    func testIsInterludeTextForBlank() {
        XCTAssertTrue(LyricsTranslationMerger.isInterludeText(""))
        XCTAssertTrue(LyricsTranslationMerger.isInterludeText("   "))
        XCTAssertTrue(LyricsTranslationMerger.isInterludeText(nil))
    }

    func testIsInterludeTextForMarkers() {
        XCTAssertTrue(LyricsTranslationMerger.isInterludeText("[間奏]"))
        XCTAssertTrue(LyricsTranslationMerger.isInterludeText("[interlude]"))
        XCTAssertTrue(LyricsTranslationMerger.isInterludeText("(interlude)"))
        XCTAssertTrue(LyricsTranslationMerger.isInterludeText("[INTERLUDE]"))
    }

    func testIsInterludeTextFalseForLyricLine() {
        XCTAssertFalse(LyricsTranslationMerger.isInterludeText("Hello there"))
    }

    // MARK: - mergeTimedWithJaLRC

    func testMergeTimedWithJaLRCMatchesByTimestamp() {
        let primary = [
            LRCParser.TimedLine(id: 1, startTime: 1.0, text: "Hello"),
            LRCParser.TimedLine(id: 2, startTime: 2.0, text: "World"),
        ]
        let translation = [
            LRCParser.TimedLine(id: 1, startTime: 2.0, text: "世界"),
            LRCParser.TimedLine(id: 2, startTime: 1.0, text: "こんにちは"),
        ]
        let merged = LyricsTranslationMerger.mergeTimedWithJaLRC(primary: primary, translation: translation)
        XCTAssertEqual(merged.map(\.translation), ["こんにちは", "世界"])
    }

    func testMergeTimedWithJaLRCFallsBackToPositionalWhenTimestampsDontMatch() {
        let primary = [
            LRCParser.TimedLine(id: 1, startTime: 1.0, text: "Hello"),
            LRCParser.TimedLine(id: 2, startTime: 2.0, text: "World"),
        ]
        let translation = [
            LRCParser.TimedLine(id: 1, startTime: 9.0, text: "こんにちは"),
            LRCParser.TimedLine(id: 2, startTime: 9.5, text: "世界"),
        ]
        let merged = LyricsTranslationMerger.mergeTimedWithJaLRC(primary: primary, translation: translation)
        XCTAssertEqual(merged.map(\.translation), ["こんにちは", "世界"])
    }

    func testMergeTimedWithJaLRCTimestampsRoundedToMilliseconds() {
        let primary = [LRCParser.TimedLine(id: 1, startTime: 1.0001, text: "Hello")]
        let translation = [LRCParser.TimedLine(id: 1, startTime: 1.00012, text: "こんにちは")]
        let merged = LyricsTranslationMerger.mergeTimedWithJaLRC(primary: primary, translation: translation)
        XCTAssertEqual(merged.first?.translation, "こんにちは")
    }

    func testMergeTimedWithJaLRCNeverTranslatesInterlude() {
        let primary = [LRCParser.TimedLine(id: 1, startTime: 1.0, text: "")]
        let translation = [LRCParser.TimedLine(id: 1, startTime: 1.0, text: "何か")]
        let merged = LyricsTranslationMerger.mergeTimedWithJaLRC(primary: primary, translation: translation)
        XCTAssertNil(merged.first?.translation)
    }

    // MARK: - mergeTimedWithJaTxt

    func testMergeTimedWithJaTxtIsPositional() {
        let primary = [
            LRCParser.TimedLine(id: 1, startTime: 1.0, text: "Hello"),
            LRCParser.TimedLine(id: 2, startTime: 2.0, text: "World"),
        ]
        let merged = LyricsTranslationMerger.mergeTimedWithJaTxt(primary: primary, translationText: "こんにちは\n世界")
        XCTAssertEqual(merged.map(\.translation), ["こんにちは", "世界"])
    }

    func testMergeTimedWithJaTxtNeverTranslatesInterlude() {
        let primary = [LRCParser.TimedLine(id: 1, startTime: 1.0, text: "[間奏]")]
        let merged = LyricsTranslationMerger.mergeTimedWithJaTxt(primary: primary, translationText: "何か")
        XCTAssertNil(merged.first?.translation)
    }

    // MARK: - mergePlainWithJaTxt

    func testMergePlainWithJaTxtIsPositional() {
        let merged = LyricsTranslationMerger.mergePlainWithJaTxt(primaryText: "Hello\nWorld", translationText: "こんにちは\n世界")
        XCTAssertEqual(merged.map(\.translation), ["こんにちは", "世界"])
    }

    func testMergePlainWithJaTxtNeverTranslatesBlankLine() {
        let merged = LyricsTranslationMerger.mergePlainWithJaTxt(primaryText: "Hello\n\nWorld", translationText: "こんにちは\n何か\n世界")
        XCTAssertEqual(merged.map(\.translation), ["こんにちは", nil, "世界"])
    }

    func testMergePlainWithJaTxtHandlesMismatchedLineCounts() {
        let merged = LyricsTranslationMerger.mergePlainWithJaTxt(primaryText: "Hello", translationText: "こんにちは\n余分")
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].translation, "こんにちは")
    }
}
