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

@MainActor
final class LibraryMembershipStoreUndecodableDataTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "test.library.membership.undecodable.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSong(id: String) -> Song {
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

    func testUndecodablePersistedDataIsBackedUpBeforeNextSave() throws {
        let defaults = try makeDefaults()
        let key = AppConstants.youtubeLibrarySongsMetaKey
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: key)

        let store = LibraryMembershipStore(defaults: defaults)
        store.add(makeSong(id: "yt-1"))

        XCTAssertEqual(defaults.data(forKey: key + ".undecodable-backup"), corrupt)
        XCTAssertTrue(store.contains(songId: "yt-1"))
    }

    func testAbsentPersistedDataCreatesNoBackup() throws {
        let defaults = try makeDefaults()
        let key = AppConstants.youtubeLibrarySongsMetaKey
        let store = LibraryMembershipStore(defaults: defaults)
        store.add(makeSong(id: "yt-1"))
        XCTAssertNil(defaults.data(forKey: key + ".undecodable-backup"))
    }
}
