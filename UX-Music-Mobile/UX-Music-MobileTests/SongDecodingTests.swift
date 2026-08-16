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

    /// Desktop library entries have no `type`/`sourceType` key at all for pre-existing local
    /// songs (see `internal/scanner.Song`), so decoding must default to `.local` rather than fail.
    func testDecodesLocalSongWithoutTypeDefaultsToLocal() throws {
        let json = """
        {"id": "abc", "path": "/music/a.m4a", "title": "T"}
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertEqual(song.sourceType, .local)
        XCTAssertFalse(song.isYouTube)
    }

    /// YouTube library entries are registered by `AddYouTubeLink` with `"type": "youtube"` and
    /// `"sourceURL"` holding the original video URL (see `server/app_youtube.go`).
    func testDecodesYouTubeSongFromDesktopLibraryPayload() throws {
        let json = """
        {
          "id": "yt1",
          "path": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          "title": "Sample",
          "artist": "Channel",
          "type": "youtube",
          "sourceURL": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        }
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertEqual(song.sourceType, .youtube)
        XCTAssertTrue(song.isYouTube)
        XCTAssertEqual(song.sourceURL, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    /// `hasLocalAudio` is additive on `GET /v1/remote/songs` (`progress/tvos-relay-reception.md`
    /// 追記): an older desktop, or any payload predating the field, omits it entirely. Missing must
    /// decode to `nil` and read as `true` via `effectiveHasLocalAudio`, never `false` — treating a
    /// merely-unpopulated field as "no local audio" would wrongly force every YouTube song onto the
    /// via-PC relay path even when the desktop can serve the file directly.
    func testDecodesSongWithoutHasLocalAudioDefaultsToNilAndEffectiveTrue() throws {
        let json = """
        {"id": "abc", "path": "/music/a.m4a", "title": "T", "type": "youtube"}
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertNil(song.hasLocalAudio)
        XCTAssertTrue(song.effectiveHasLocalAudio)
    }

    func testDecodesSongWithHasLocalAudioFalse() throws {
        let json = """
        {"id": "abc", "path": "", "title": "T", "type": "youtube", "hasLocalAudio": false}
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertEqual(song.hasLocalAudio, false)
        XCTAssertFalse(song.effectiveHasLocalAudio)
    }
}
