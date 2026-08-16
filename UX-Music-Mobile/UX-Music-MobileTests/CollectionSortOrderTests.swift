import XCTest
@testable import UX_Music_Mobile

final class CollectionSortOrderTests: XCTestCase {
    private func song(
        id: String,
        title: String = "",
        artist: String = "",
        album: String = "",
        track: Int = 0,
        disc: Int = 0
    ) -> Song {
        Song(id: id, path: "/x/\(id)", title: title, artist: artist, album: album, trackNumber: track, discNumber: disc)
    }

    private func album(id: String, name: String, artist: String, songCount: Int) -> Album {
        Album(
            normalisedAlbumTitle: name,
            artistName: artist,
            artworkId: "",
            songs: (0..<songCount).map { song(id: "\(id)-\($0)") }
        )
    }

    private func artist(name: String, songCount: Int) -> Artist {
        let songs = (0..<songCount).map { song(id: "\(name)-\($0)") }
        return Artist(normalisedArtistName: name, songs: songs, albums: [], artworkId: "")
    }

    // MARK: - AlbumSortOrder

    /// Pins both locales' translations directly (rather than the running test host's current
    /// locale) so a regression in either language is caught regardless of which locale the test
    /// happens to run under. `displayName` itself still resolves via the current locale.
    func testAlbumDisplayNamesAreLocalized() {
        XCTAssertEqual(AlbumSortOrder.name.displayName, localizedString("By Album Name"))
        XCTAssertEqual(AlbumSortOrder.artist.displayName, localizedString("By Artist Name"))
        XCTAssertEqual(AlbumSortOrder.songCount.displayName, localizedString("By Song Count"))

        XCTAssertEqual(localizedString("By Album Name", locale: "ja"), "アルバム名順")
        XCTAssertEqual(localizedString("By Artist Name", locale: "ja"), "アーティスト名順")
        XCTAssertEqual(localizedString("By Song Count", locale: "ja"), "曲数順")

        XCTAssertEqual(localizedString("By Album Name", locale: "en"), "By Album Name")
        XCTAssertEqual(localizedString("By Artist Name", locale: "en"), "By Artist Name")
        XCTAssertEqual(localizedString("By Song Count", locale: "en"), "By Song Count")
    }

    func testAlbumNameOrderSortsAlphabeticallyLikeExistingDefault() {
        let albums = [
            album(id: "1", name: "Zebra", artist: "A", songCount: 1),
            album(id: "2", name: "Apple", artist: "A", songCount: 1),
        ]
        let expected = albums.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }.map(\.id)
        XCTAssertEqual(AlbumSortOrder.name.sorted(albums).map(\.id), expected)
        XCTAssertEqual(AlbumSortOrder.name.sorted(albums).map(\.id), ["Apple", "Zebra"])
    }

    func testAlbumArtistOrderSortsAlphabeticallyByArtist() {
        let albums = [
            album(id: "1", name: "A1", artist: "Zeta", songCount: 1),
            album(id: "2", name: "A2", artist: "Alpha", songCount: 1),
        ]
        XCTAssertEqual(AlbumSortOrder.artist.sorted(albums).map(\.id), ["A2", "A1"])
    }

    func testAlbumArtistOrderFallsBackToAlbumNameOnTie() {
        let albums = [
            album(id: "1", name: "Beta", artist: "Same", songCount: 1),
            album(id: "2", name: "Alpha", artist: "Same", songCount: 1),
        ]
        // Ties on artist fall back to album name ordering ("Alpha" before "Beta").
        XCTAssertEqual(AlbumSortOrder.artist.sorted(albums).map(\.id), ["Alpha", "Beta"])
    }

    func testAlbumSongCountOrderSortsDescending() {
        let albums = [
            album(id: "1", name: "Few", artist: "A", songCount: 2),
            album(id: "2", name: "Many", artist: "A", songCount: 9),
        ]
        XCTAssertEqual(AlbumSortOrder.songCount.sorted(albums).map(\.id), ["Many", "Few"])
    }

    func testAlbumSongCountOrderFallsBackToAlbumNameOnTie() {
        let albums = [
            album(id: "1", name: "Beta", artist: "A", songCount: 3),
            album(id: "2", name: "Alpha", artist: "A", songCount: 3),
        ]
        XCTAssertEqual(AlbumSortOrder.songCount.sorted(albums).map(\.id), ["Alpha", "Beta"])
    }

    func testAlbumNameOrderIsStableAgainstAlreadySortedInput() {
        let albums = [
            album(id: "1", name: "Alpha", artist: "A", songCount: 1),
            album(id: "2", name: "Beta", artist: "A", songCount: 1),
            album(id: "3", name: "Gamma", artist: "A", songCount: 1),
        ]
        XCTAssertEqual(AlbumSortOrder.name.sorted(albums).map(\.id), ["Alpha", "Beta", "Gamma"])
    }

    // MARK: - ArtistSortOrder

    /// Pins both locales' translations directly (rather than the running test host's current
    /// locale) so a regression in either language is caught regardless of which locale the test
    /// happens to run under. `displayName` itself still resolves via the current locale.
    func testArtistDisplayNamesAreLocalized() {
        XCTAssertEqual(ArtistSortOrder.name.displayName, localizedString("By Name"))
        XCTAssertEqual(ArtistSortOrder.songCount.displayName, localizedString("By Song Count"))

        XCTAssertEqual(localizedString("By Name", locale: "ja"), "名前順")
        XCTAssertEqual(localizedString("By Song Count", locale: "ja"), "曲数順")

        XCTAssertEqual(localizedString("By Name", locale: "en"), "By Name")
        XCTAssertEqual(localizedString("By Song Count", locale: "en"), "By Song Count")
    }

    func testArtistNameOrderSortsAlphabeticallyLikeExistingDefault() {
        let artists = [artist(name: "Zebra", songCount: 1), artist(name: "Apple", songCount: 1)]
        let expected = artists.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }.map(\.id)
        XCTAssertEqual(ArtistSortOrder.name.sorted(artists).map(\.id), expected)
        XCTAssertEqual(ArtistSortOrder.name.sorted(artists).map(\.id), ["Apple", "Zebra"])
    }

    func testArtistSongCountOrderSortsDescending() {
        let artists = [artist(name: "Few", songCount: 2), artist(name: "Many", songCount: 9)]
        XCTAssertEqual(ArtistSortOrder.songCount.sorted(artists).map(\.id), ["Many", "Few"])
    }

    func testArtistSongCountOrderFallsBackToNameOnTie() {
        let artists = [artist(name: "Beta", songCount: 3), artist(name: "Alpha", songCount: 3)]
        XCTAssertEqual(ArtistSortOrder.songCount.sorted(artists).map(\.id), ["Alpha", "Beta"])
    }

    func testArtistNameOrderIsStableAgainstAlreadySortedInput() {
        let artists = [artist(name: "Alpha", songCount: 1), artist(name: "Beta", songCount: 1), artist(name: "Gamma", songCount: 1)]
        XCTAssertEqual(ArtistSortOrder.name.sorted(artists).map(\.id), ["Alpha", "Beta", "Gamma"])
    }
}
