import XCTest
@testable import UX_Music_Mobile

final class AlbumTests: XCTestCase {
    func testFromSongsGroupsAndSortsTracks() {
        let s1 = Song(id: "1", path: "", artist: "Ar", album: "B", albumArtist: "AA", trackNumber: 2, discNumber: 1, artworkId: "w")
        let s2 = Song(id: "2", path: "", artist: "Ar", album: "B", albumArtist: "AA", trackNumber: 1, discNumber: 1, artworkId: "w")
        let s3 = Song(id: "3", path: "", artist: "X", album: "A", albumArtist: "X", trackNumber: 1, discNumber: 1, artworkId: "y")

        let albums = Album.fromSongs([s1, s2, s3])
        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums[0].displayName, "A")
        XCTAssertEqual(albums[1].songs.map(\Song.id), ["2", "1"])
    }

    /// Compilations often omit `albumartist`; grouping must not split by per-track `artist`.
    func testCompilationMergedWhenAlbumArtistEmpty() {
        let s1 = Song(id: "1", path: "", artist: "Alice", album: "Summer Hits", albumArtist: "", trackNumber: 1, discNumber: 1, artworkId: "art")
        let s2 = Song(id: "2", path: "", artist: "Bob", album: "Summer Hits", albumArtist: "", trackNumber: 2, discNumber: 1, artworkId: "art")

        let albums = Album.fromSongs([s1, s2])
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].displayName, "Summer Hits")
        XCTAssertEqual(albums[0].displayArtist, "Various Artists")
        XCTAssertEqual(Set(albums[0].songs.map(\Song.id)), ["1", "2"])
    }

    func testSingleAlbumArtistTagUnifiesCompilation() {
        let s1 = Song(id: "1", path: "", artist: "Alice", album: "OST", albumArtist: "Various Artists", trackNumber: 1, discNumber: 1, artworkId: "x")
        let s2 = Song(id: "2", path: "", artist: "Bob", album: "OST", albumArtist: "Various Artists", trackNumber: 2, discNumber: 1, artworkId: "x")

        let albums = Album.fromSongs([s1, s2])
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].displayArtist, "Various Artists")
    }
}
