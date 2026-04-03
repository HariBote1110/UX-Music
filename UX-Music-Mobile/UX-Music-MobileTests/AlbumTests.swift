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

    /// When disc/track tags are missing (0), order must not be arbitrary — use title.
    func testFromSongsSortsByTitleWhenDiscAndTrackAreZero() {
        let zebra = Song(id: "z", path: "", title: "Zebra", artist: "A", album: "LP", albumArtist: "A", trackNumber: 0, discNumber: 0, artworkId: "")
        let alpha = Song(id: "a", path: "", title: "Alpha", artist: "A", album: "LP", albumArtist: "A", trackNumber: 0, discNumber: 0, artworkId: "")
        let albums = Album.fromSongs([zebra, alpha])
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].songs.map(\Song.id), ["a", "z"])
    }

    func testLibraryFlatDisplayOrderAscending() {
        let b2 = Song(id: "b2", path: "", title: "T2", artist: "A", album: "B", albumArtist: "", trackNumber: 2, discNumber: 1, artworkId: "")
        let b1 = Song(id: "b1", path: "", title: "T1", artist: "A", album: "B", albumArtist: "", trackNumber: 1, discNumber: 1, artworkId: "")
        let a1 = Song(id: "a1", path: "", title: "Z", artist: "A", album: "A", albumArtist: "", trackNumber: 1, discNumber: 1, artworkId: "")
        let sorted = [b2, a1, b1].sorted(by: Song.libraryFlatDisplayOrderAscending)
        XCTAssertEqual(sorted.map(\Song.id), ["a1", "b1", "b2"])
    }
}
