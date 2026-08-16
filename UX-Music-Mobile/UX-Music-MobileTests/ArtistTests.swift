import XCTest
@testable import UX_Music_Mobile

final class ArtistTests: XCTestCase {
    private func song(
        id: String,
        title: String = "T",
        artist: String = "",
        album: String = "",
        albumArtist: String = "",
        artworkId: String = ""
    ) -> Song {
        Song(id: id, path: "/x/\(id)", title: title, artist: artist, album: album, albumArtist: albumArtist, artworkId: artworkId)
    }

    func testGroupsByAlbumArtistWhenPresent() {
        let songs = [
            song(id: "1", artist: "Track Artist", albumArtist: "Album Artist"),
            song(id: "2", artist: "Other Track Artist", albumArtist: "Album Artist"),
        ]
        let artists = Artist.fromSongs(songs)
        XCTAssertEqual(artists.map(\.name), ["Album Artist"])
        XCTAssertEqual(artists[0].songs.map(\.id), ["1", "2"])
    }

    func testFallsBackToArtistWhenAlbumArtistBlank() {
        let songs = [song(id: "1", artist: "Solo Artist", albumArtist: "  ")]
        let artists = Artist.fromSongs(songs)
        XCTAssertEqual(artists.map(\.name), ["Solo Artist"])
    }

    func testFallsBackToUnknownArtistWhenBothBlank() {
        let songs = [song(id: "1", artist: "", albumArtist: "")]
        let artists = Artist.fromSongs(songs)
        XCTAssertEqual(artists.map(\.name), ["Unknown Artist"])
    }

    func testBuildsAlbumListForArtist() {
        let songs = [
            song(id: "1", artist: "A", album: "Album One"),
            song(id: "2", artist: "A", album: "Album Two"),
        ]
        let artists = Artist.fromSongs(songs)
        XCTAssertEqual(artists[0].albums.map(\.displayName).sorted(), ["Album One", "Album Two"])
    }

    func testArtworkIdIsRepresentativeFromSongs() {
        let songs = [
            song(id: "1", artist: "A", artworkId: ""),
            song(id: "2", artist: "A", artworkId: "art-2"),
        ]
        let artists = Artist.fromSongs(songs)
        XCTAssertEqual(artists[0].artworkId, "art-2")
    }

    func testArtistsSortedAlphabetically() {
        let songs = [song(id: "1", artist: "Zeta"), song(id: "2", artist: "Alpha")]
        let artists = Artist.fromSongs(songs)
        XCTAssertEqual(artists.map(\.name), ["Alpha", "Zeta"])
    }
}
