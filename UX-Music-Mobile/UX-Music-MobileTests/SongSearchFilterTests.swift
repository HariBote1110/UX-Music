import XCTest
@testable import UX_Music_Mobile

final class SongSearchFilterTests: XCTestCase {
    private func song(
        title: String = "",
        artist: String = "",
        album: String = "",
        albumArtist: String = ""
    ) -> Song {
        Song(id: UUID().uuidString, path: "/x", title: title, artist: artist, album: album, albumArtist: albumArtist)
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(SongSearchFilter.matches(song(title: "Anything"), query: ""))
        XCTAssertTrue(SongSearchFilter.matches(song(title: "Anything"), query: "   "))
    }

    func testMatchesTitleCaseInsensitive() {
        XCTAssertTrue(SongSearchFilter.matches(song(title: "Hello World"), query: "hello"))
    }

    func testMatchesArtist() {
        XCTAssertTrue(SongSearchFilter.matches(song(artist: "Someone"), query: "some"))
    }

    func testMatchesAlbum() {
        XCTAssertTrue(SongSearchFilter.matches(song(album: "Greatest Hits"), query: "greatest"))
    }

    func testMatchesAlbumArtist() {
        XCTAssertTrue(SongSearchFilter.matches(song(albumArtist: "Various Artists"), query: "various"))
    }

    func testDiacriticInsensitive() {
        XCTAssertTrue(SongSearchFilter.matches(song(title: "Café"), query: "cafe"))
    }

    func testWhitespaceTrimmed() {
        XCTAssertTrue(SongSearchFilter.matches(song(title: "Hello"), query: "  hello  "))
    }

    func testMultiTokenRequiresAllTokensToMatch() {
        let s = song(title: "Song", artist: "Artist Name")
        XCTAssertTrue(SongSearchFilter.matches(s, query: "song artist"))
        XCTAssertFalse(SongSearchFilter.matches(s, query: "song missing"))
    }

    func testNoMatchReturnsFalse() {
        XCTAssertFalse(SongSearchFilter.matches(song(title: "Hello"), query: "goodbye"))
    }

    func testFilterPreservesOrder() {
        let songs = [song(title: "Alpha"), song(title: "Beta"), song(title: "Alpha Two")]
        let result = SongSearchFilter.filter(songs, query: "alpha")
        XCTAssertEqual(result.map(\.title), ["Alpha", "Alpha Two"])
    }
}
