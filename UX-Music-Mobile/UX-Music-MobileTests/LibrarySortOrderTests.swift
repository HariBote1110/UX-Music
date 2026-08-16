import XCTest
@testable import UX_Music_Mobile

final class LibrarySortOrderTests: XCTestCase {
    private func song(
        id: String,
        title: String,
        artist: String = "",
        album: String = "",
        duration: Double = 0,
        track: Int = 0,
        disc: Int = 0
    ) -> Song {
        Song(id: id, path: "/x/\(id)", title: title, artist: artist, album: album, duration: duration, trackNumber: track, discNumber: disc)
    }

    /// Pins both locales' translations directly (rather than the running test host's current
    /// locale) so a regression in either language is caught regardless of which locale the test
    /// happens to run under. `displayName` itself still resolves via the current locale.
    func testDisplayNamesAreLocalized() {
        XCTAssertEqual(LibrarySortOrder.album.displayName, localizedString("By Album"))
        XCTAssertEqual(LibrarySortOrder.title.displayName, localizedString("By Title"))
        XCTAssertEqual(LibrarySortOrder.artist.displayName, localizedString("By Artist"))
        XCTAssertEqual(LibrarySortOrder.duration.displayName, localizedString("By Duration"))

        XCTAssertEqual(localizedString("By Album", locale: "ja"), "アルバム順")
        XCTAssertEqual(localizedString("By Title", locale: "ja"), "タイトル順")
        XCTAssertEqual(localizedString("By Artist", locale: "ja"), "アーティスト順")
        XCTAssertEqual(localizedString("By Duration", locale: "ja"), "再生時間順")

        XCTAssertEqual(localizedString("By Album", locale: "en"), "By Album")
        XCTAssertEqual(localizedString("By Title", locale: "en"), "By Title")
        XCTAssertEqual(localizedString("By Artist", locale: "en"), "By Artist")
        XCTAssertEqual(localizedString("By Duration", locale: "en"), "By Duration")
    }

    func testTitleOrderSortsAlphabetically() {
        let songs = [song(id: "1", title: "Zebra"), song(id: "2", title: "Apple")]
        XCTAssertEqual(LibrarySortOrder.title.sorted(songs).map(\.id), ["2", "1"])
    }

    func testArtistOrderSortsAlphabetically() {
        let songs = [song(id: "1", title: "T1", artist: "Zeta"), song(id: "2", title: "T2", artist: "Alpha")]
        XCTAssertEqual(LibrarySortOrder.artist.sorted(songs).map(\.id), ["2", "1"])
    }

    func testDurationOrderSortsAscending() {
        let songs = [song(id: "1", title: "T1", duration: 300), song(id: "2", title: "T2", duration: 120)]
        XCTAssertEqual(LibrarySortOrder.duration.sorted(songs).map(\.id), ["2", "1"])
    }

    func testAlbumOrderMatchesExistingLibraryFlatDisplayOrder() {
        let songs = [
            song(id: "1", title: "T1", album: "Beta", track: 2),
            song(id: "2", title: "T2", album: "Alpha", track: 1),
        ]
        let expected = songs.sorted(by: Song.libraryFlatDisplayOrderAscending).map(\.id)
        XCTAssertEqual(LibrarySortOrder.album.sorted(songs).map(\.id), expected)
    }

    func testTitleOrderFallsBackToAlbumOrderOnTie() {
        let songs = [
            song(id: "1", title: "Same", album: "Beta"),
            song(id: "2", title: "Same", album: "Alpha"),
        ]
        // Ties on title fall back to album ordering ("Alpha" before "Beta").
        XCTAssertEqual(LibrarySortOrder.title.sorted(songs).map(\.id), ["2", "1"])
    }

    func testDurationOrderFallsBackToAlbumOrderOnTie() {
        let songs = [
            song(id: "1", title: "T1", album: "Beta", duration: 100),
            song(id: "2", title: "T2", album: "Alpha", duration: 100),
        ]
        XCTAssertEqual(LibrarySortOrder.duration.sorted(songs).map(\.id), ["2", "1"])
    }
}
