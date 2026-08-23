import XCTest
@testable import UX_Music_Mobile

/// Covers `Artist.fromSongs(_:precomputedAlbums:)` — the overload `LibraryDerivedCollections`
/// uses so the Artists tab does not redo `Album.fromSongs`'s grouping/sort work the Albums tab
/// already paid for. It must produce output identical to `Artist.fromSongs(_:)` given the same
/// songs.
final class ArtistPrecomputedAlbumsTests: XCTestCase {
    private func song(
        id: String,
        title: String = "T",
        artist: String = "",
        album: String = "",
        albumArtist: String = "",
        trackNumber: Int = 0,
        discNumber: Int = 0,
        artworkId: String = ""
    ) -> Song {
        Song(
            id: id,
            path: "/x/\(id)",
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            trackNumber: trackNumber,
            discNumber: discNumber,
            artworkId: artworkId
        )
    }

    func testMatchesFromSongsForSimpleLibrary() {
        let songs = [
            song(id: "1", title: "One", artist: "A", album: "Album One", albumArtist: "A", trackNumber: 1),
            song(id: "2", title: "Two", artist: "A", album: "Album One", albumArtist: "A", trackNumber: 2),
            song(id: "3", title: "Three", artist: "B", album: "Album Two", albumArtist: "B", trackNumber: 1),
        ]

        let expected = Artist.fromSongs(songs)
        let actual = Artist.fromSongs(songs, precomputedAlbums: Album.fromSongs(songs))

        XCTAssertEqual(actual.map(\.name), expected.map(\.name))
        XCTAssertEqual(actual.map { $0.songs.map(\.id) }, expected.map { $0.songs.map(\.id) })
        XCTAssertEqual(actual.map { $0.albums.map(\.displayName) }, expected.map { $0.albums.map(\.displayName) })
        XCTAssertEqual(actual.map { $0.albums.map { $0.songs.map(\.id) } }, expected.map { $0.albums.map { $0.songs.map(\.id) } })
        XCTAssertEqual(actual.map(\.artworkId), expected.map(\.artworkId))
    }

    /// Compilation album split across two artists: each artist's album entry must only contain
    /// their own tracks, and its representative artist name must reflect just that subset — same
    /// as the original `fromSongs(_:)` behaviour.
    func testMatchesFromSongsForCompilationAlbum() {
        let songs = [
            song(id: "1", title: "Alice Track", artist: "Alice", album: "Compilation", albumArtist: "", trackNumber: 1),
            song(id: "2", title: "Bob Track", artist: "Bob", album: "Compilation", albumArtist: "", trackNumber: 2),
            song(id: "3", title: "Alice Solo", artist: "Alice", album: "Alice Solo Album", albumArtist: "Alice", trackNumber: 1),
        ]

        let expected = Artist.fromSongs(songs)
        let actual = Artist.fromSongs(songs, precomputedAlbums: Album.fromSongs(songs))

        XCTAssertEqual(actual.map(\.name).sorted(), expected.map(\.name).sorted())
        for artistName in expected.map(\.name) {
            let expectedArtist = expected.first { $0.name == artistName }!
            let actualArtist = actual.first { $0.name == artistName }!
            XCTAssertEqual(
                actualArtist.albums.map { ($0.displayName, $0.artistName, $0.songs.map(\.id)) }.map(String.init(describing:)),
                expectedArtist.albums.map { ($0.displayName, $0.artistName, $0.songs.map(\.id)) }.map(String.init(describing:))
            )
        }
    }

    func testMatchesFromSongsWithDiscAndTrackOrdering() {
        let songs = [
            song(id: "b", title: "B", artist: "A", album: "LP", albumArtist: "A", trackNumber: 2, discNumber: 1),
            song(id: "a", title: "A", artist: "A", album: "LP", albumArtist: "A", trackNumber: 1, discNumber: 1),
            song(id: "c", title: "C", artist: "A", album: "LP", albumArtist: "A", trackNumber: 1, discNumber: 2),
        ]

        let expected = Artist.fromSongs(songs)
        let actual = Artist.fromSongs(songs, precomputedAlbums: Album.fromSongs(songs))

        XCTAssertEqual(actual[0].albums[0].songs.map(\.id), expected[0].albums[0].songs.map(\.id))
        XCTAssertEqual(actual[0].albums[0].songs.map(\.id), ["a", "b", "c"])
    }

    func testEmptyLibraryProducesNoArtists() {
        XCTAssertEqual(Artist.fromSongs([], precomputedAlbums: []), [])
    }
}
