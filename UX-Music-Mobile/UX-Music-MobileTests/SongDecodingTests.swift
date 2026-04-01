import XCTest
@testable import UX_Music_Mobile

final class SongDecodingTests: XCTestCase {
    func testDecodesWearSongJSON() throws {
        let json = """
        {
          "id": "abc",
          "path": "/music/a.m4a",
          "title": "T",
          "artist": "A",
          "album": "Al",
          "albumartist": "AA",
          "year": 2020,
          "genre": "g",
          "duration": 125.5,
          "trackNumber": 3,
          "discNumber": 1,
          "fileSize": 100,
          "fileType": "m4a",
          "artworkId": "hash1"
        }
        """.data(using: .utf8)!

        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertEqual(song.id, "abc")
        XCTAssertEqual(song.albumArtist, "AA")
        XCTAssertEqual(song.artworkId, "hash1")
        XCTAssertEqual(song.duration, 125.5, accuracy: 0.01)
        XCTAssertEqual(song.displayTitle, "T")
    }

    func testEncodesRoundTrip() throws {
        let song = Song(id: "x", path: "/p", title: "Hi", artworkId: "art")
        let data = try JSONEncoder().encode(song)
        let back = try JSONDecoder().decode(Song.self, from: data)
        XCTAssertEqual(back.id, "x")
        XCTAssertEqual(back.artworkId, "art")
    }
}
