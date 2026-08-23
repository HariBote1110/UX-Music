import XCTest
@testable import UX_Music_Mobile

/// Covers `LibraryDerivedCollections` — the memoisation layer `LocalLibraryScreen` uses so
/// switching Songs/Albums/Artists tabs does not re-run `Album.fromSongs`/`Artist.fromSongs` and
/// their sort/search passes on every SwiftUI body evaluation.
final class LibraryDerivedCollectionsTests: XCTestCase {
    private func song(id: String, title: String = "T", artist: String = "A", album: String = "Alb") -> Song {
        Song(id: id, path: "/x/\(id)", title: title, artist: artist, album: album, albumArtist: artist)
    }

    private func inputs(
        revision: Int = 1,
        library: LibrarySortOrder = .album,
        albumOrder: AlbumSortOrder = .name,
        artistOrder: ArtistSortOrder = .name,
        query: String = ""
    ) -> LibraryDerivedCollections.Inputs {
        LibraryDerivedCollections.Inputs(
            libraryRevision: revision,
            librarySortOrder: library,
            albumSortOrder: albumOrder,
            artistSortOrder: artistOrder,
            searchQuery: query
        )
    }

    func testComputesDerivedCollectionsFromSongs() {
        let songs = [song(id: "1"), song(id: "2", artist: "B", album: "Other")]
        let cache = LibraryDerivedCollections().updated(songs: songs, inputs: inputs())

        XCTAssertEqual(cache.sortedSongs.map(\.id).sorted(), ["1", "2"])
        XCTAssertEqual(cache.searchedAlbums.count, 2)
        XCTAssertEqual(cache.searchedArtists.count, 2)
    }

    /// The core perf guarantee: calling `updated` again with an unchanged `Inputs` must return the
    /// same value without recomputing — even if the `songs` argument passed in differs (e.g. a
    /// caller re-reading the model's song list on a body re-evaluation the cache should ignore).
    func testSameInputsSkipsRecomputation() {
        let songsA = [song(id: "1"), song(id: "2")]
        let cached = LibraryDerivedCollections().updated(songs: songsA, inputs: inputs())

        let songsB = [song(id: "9")] // deliberately different — must be ignored since inputs match
        let stillCached = cached.updated(songs: songsB, inputs: inputs())

        XCTAssertEqual(stillCached.sortedSongs.map(\.id), cached.sortedSongs.map(\.id))
        XCTAssertEqual(stillCached.sortedSongs.map(\.id), ["1", "2"])
    }

    func testChangedRevisionTriggersRecomputation() {
        let songsA = [song(id: "1")]
        let cached = LibraryDerivedCollections().updated(songs: songsA, inputs: inputs(revision: 1))

        let songsB = [song(id: "1"), song(id: "2")]
        let updated = cached.updated(songs: songsB, inputs: inputs(revision: 2))

        XCTAssertEqual(updated.sortedSongs.map(\.id).sorted(), ["1", "2"])
    }

    func testChangedSearchQueryTriggersRecomputationAndFilters() {
        let songs = [song(id: "1", title: "Alpha"), song(id: "2", title: "Beta")]
        let cached = LibraryDerivedCollections().updated(songs: songs, inputs: inputs())
        let filtered = cached.updated(songs: songs, inputs: inputs(query: "Alpha"))

        XCTAssertEqual(filtered.searchedSongs.map(\.id), ["1"])
        XCTAssertNotEqual(filtered.inputs, cached.inputs)
    }

    func testChangedSortOrderTriggersRecomputation() {
        let songs = [song(id: "1", title: "Zeta"), song(id: "2", title: "Alpha")]
        let byAlbum = LibraryDerivedCollections().updated(songs: songs, inputs: inputs(library: .album))
        let byTitle = byAlbum.updated(songs: songs, inputs: inputs(library: .title))

        XCTAssertEqual(byTitle.sortedSongs.map(\.id), ["2", "1"])
    }
}
