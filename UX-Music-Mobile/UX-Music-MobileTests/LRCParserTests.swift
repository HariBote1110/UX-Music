import XCTest
@testable import UX_Music_Mobile

final class LRCParserTests: XCTestCase {
    func testParseSkipsMetadataTags() {
        let raw = """
        [ti:Title]
        [ar:Artist]
        [00:12.00]First line
        [00:15.50]Second
        """
        let lines = LRCParser.parseTimedLines(raw)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].startTime, 12.0, accuracy: 0.01)
        XCTAssertEqual(lines[0].text, "First line")
        XCTAssertEqual(lines[1].startTime, 15.5, accuracy: 0.01)
    }

    func testActiveLineUsesLastStartedBeforeOrAtTime() {
        let lines = [
            LRCParser.TimedLine(id: 0, startTime: 10, text: "A"),
            LRCParser.TimedLine(id: 1, startTime: 20, text: "B"),
            LRCParser.TimedLine(id: 2, startTime: 30, text: "C")
        ]
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 5), 0)
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 10), 0)
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 25), 1)
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 30), 2)
        XCTAssertEqual(LRCParser.activeLineIndex(in: lines, at: 99), 2)
    }

    func testParseHoursMinutesSeconds() {
        let raw = "[01:02:03.50]End stretch"
        let lines = LRCParser.parseTimedLines(raw)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].startTime, 3600 + 120 + 3.5, accuracy: 0.01)
        XCTAssertEqual(lines[0].text, "End stretch")
    }

    func testParseThreeDigitFractionAsMilliseconds() {
        let raw = "[00:01.350]Ms"
        let lines = LRCParser.parseTimedLines(raw)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].startTime, 1.35, accuracy: 0.02)
    }
}
