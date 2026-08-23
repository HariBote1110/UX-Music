import Foundation

/// Memoised bundle of the grouped/sorted collections `LocalLibraryScreen` needs for its Songs/
/// Albums/Artists tabs.
///
/// `Album.fromSongs`/`Artist.fromSongs` (and the sort/search passes on top of them) are O(N log N)
/// — cheap once, but when they lived as plain computed properties on the view they re-ran on
/// *every* SwiftUI body evaluation, including ones triggered by unrelated state (the tab-flip
/// paging animation itself re-evaluates the body many times per second). That showed up as dropped
/// frames flipping between Songs/Albums/Artists on a library of any real size. This type recomputes
/// only when one of its declared `Inputs` actually changed, and is otherwise a cheap `Equatable`
/// check away from a no-op — store it in `@State` and refresh via `.task(id:)`/`.onChange` keyed on
/// `Inputs`, never inline in `body`.
struct LibraryDerivedCollections: Equatable {
    /// Everything the derived collections depend on. Two `Inputs` comparing equal guarantees the
    /// derived output would be identical, so `updated(songs:inputs:)` can skip recomputation.
    ///
    /// `libraryRevision` stands in for the song list's *content* (rather than hashing every song
    /// on each check) — it mirrors `AppModel.downloadLibraryRevision`, which the model already
    /// bumps exactly when the downloaded/library song set changes.
    struct Inputs: Equatable {
        var libraryRevision: Int
        var librarySortOrder: LibrarySortOrder
        var albumSortOrder: AlbumSortOrder
        var artistSortOrder: ArtistSortOrder
        var searchQuery: String
    }

    private(set) var inputs: Inputs?
    private(set) var sortedSongs: [Song] = []
    private(set) var searchedSongs: [Song] = []
    private(set) var searchedAlbums: [Album] = []
    private(set) var searchedArtists: [Artist] = []

    /// Returns a `LibraryDerivedCollections` reflecting `songs`/`inputs`. If `inputs` matches the
    /// value this instance was last computed from, returns `self` unchanged; otherwise recomputes
    /// every derived collection once and returns a fresh value.
    ///
    /// `songs` must be the up-to-date, unsorted library song set for `inputs.libraryRevision` —
    /// callers only need to pay for producing it when a recompute is actually about to happen, so
    /// prefer passing an `@autoclosure`-style lazily-evaluated source at the call site (e.g. read
    /// `model.sortedDownloadedSongsForLibrary` only inside the branch that calls this).
    func updated(songs: [Song], inputs newInputs: Inputs) -> LibraryDerivedCollections {
        guard inputs != newInputs else { return self }

        let groupedAlbums = Album.fromSongs(songs)

        var result = LibraryDerivedCollections()
        result.inputs = newInputs

        result.sortedSongs = newInputs.librarySortOrder.sorted(songs)
        result.searchedSongs = SongSearchFilter.filter(result.sortedSongs, query: newInputs.searchQuery)

        let sortedAlbums = newInputs.albumSortOrder.sorted(groupedAlbums)
        result.searchedAlbums = newInputs.searchQuery.isEmpty
            ? sortedAlbums
            : sortedAlbums.filter { !SongSearchFilter.filter($0.songs, query: newInputs.searchQuery).isEmpty }

        let artists = Artist.fromSongs(songs, precomputedAlbums: groupedAlbums)
        let sortedArtists = newInputs.artistSortOrder.sorted(artists)
        result.searchedArtists = newInputs.searchQuery.isEmpty
            ? sortedArtists
            : sortedArtists.filter { !SongSearchFilter.filter($0.songs, query: newInputs.searchQuery).isEmpty }

        return result
    }
}
