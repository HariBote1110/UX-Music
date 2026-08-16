import XCTest
@testable import UX_Music_Mobile

@MainActor
final class LibraryMembershipStoreTests: XCTestCase {
    private func makeYouTubeSong(id: String) -> Song {
        Song(
            id: id,
            path: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            title: "T",
            artist: "Ar",
            album: "Al",
            albumArtist: "AA",
            artworkId: "",
            sourceType: .youtube,
            sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
    }

    func testAddAndContainsRoundTripsThroughPersistence() {
        let id = "unit-test-yt-\(UUID().uuidString)"
        let song = makeYouTubeSong(id: id)

        var store: LibraryMembershipStore? = LibraryMembershipStore()
        store?.add(song)
        XCTAssertTrue(store?.contains(songId: id) ?? false)
        store = nil

        // A fresh instance must see the same membership from UserDefaults.
        let reloaded = LibraryMembershipStore()
        XCTAssertTrue(reloaded.contains(songId: id))
        XCTAssertEqual(reloaded.songs[id]?.title, "T")

        reloaded.remove(songId: id)
        XCTAssertFalse(reloaded.contains(songId: id))
        XCTAssertFalse(LibraryMembershipStore().contains(songId: id))
    }

    func testRemoveOfAbsentIdIsANoop() {
        let store = LibraryMembershipStore()
        store.remove(songId: "does-not-exist-\(UUID().uuidString)")
        // No crash, no error — nothing to assert beyond survival.
    }
}
