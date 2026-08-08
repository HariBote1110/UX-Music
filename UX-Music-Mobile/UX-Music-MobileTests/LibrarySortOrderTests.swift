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

    func testDisplayNamesAreJapanese() {
        XCTAssertEqual(LibrarySortOrder.album.displayName, "アルバム順")
        XCTAssertEqual(LibrarySortOrder.title.displayName, "タイトル順")
        XCTAssertEqual(LibrarySortOrder.artist.displayName, "アーティスト順")
        XCTAssertEqual(LibrarySortOrder.duration.displayName, "再生時間順")
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
