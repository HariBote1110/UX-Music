import XCTest
@testable import UX_Music_TV

final class TVPlayEventPolicyTests: XCTestCase {
    private func song(id: String, duration: Double) -> Song {
        Song(
            id: id, path: "/tmp/\(id).flac", title: "T", artist: "A", album: "Al",
            albumArtist: "A", year: 2024, genre: "", duration: duration, trackNumber: 1,
            discNumber: 1, fileSize: 0, fileType: "flac", sampleRate: nil, bitDepth: nil,
            artworkId: "", sourceType: .local, sourceURL: nil
        )
    }

    func testReportsNormalFinishedSong() {
        XCTAssertTrue(TVPlayEventPolicy.shouldReport(song: song(id: "a", duration: 180)))
    }

    func testDoesNotReportEmptyId() {
        XCTAssertFalse(TVPlayEventPolicy.shouldReport(song: song(id: "", duration: 180)))
    }

    func testDoesNotReportNonPositiveDuration() {
        XCTAssertFalse(TVPlayEventPolicy.shouldReport(song: song(id: "a", duration: 0)))
        XCTAssertFalse(TVPlayEventPolicy.shouldReport(song: song(id: "a", duration: -1)))
    }

    func testRFC3339FormatIsUTCWithFractionalSeconds() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)

        let formatted = TVPlayEventPolicy.rfc3339(date)

        XCTAssertTrue(formatted.hasSuffix("Z"), "expected UTC 'Z' suffix, got \(formatted)")
        XCTAssertTrue(formatted.contains("."), "expected fractional seconds, got \(formatted)")
        // Round-trips through the same formatter configuration.
        let parser = ISO8601DateFormatter()
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = parser.date(from: formatted)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }
}
