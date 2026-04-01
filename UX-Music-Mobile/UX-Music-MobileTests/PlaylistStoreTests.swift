import XCTest
@testable import UX_Music_Mobile

@MainActor
final class PlaylistStoreTests: XCTestCase {
    private func makeStore() -> PlaylistStore {
        let suiteName = "test.playlist.store.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("UserDefaults suite missing")
            fatalError()
        }
        defaults.removePersistentDomain(forName: suiteName)
        return PlaylistStore(defaults: defaults, persistenceKey: AppConstants.playlistsPersistenceKey)
    }

    func testLoadEmptyThenRoundTrip() throws {
        let store = makeStore()
        store.load()
        XCTAssertTrue(store.orderedPlaylists().isEmpty)

        _ = try store.createPlaylist(name: "Alpha")
        store.load()
        XCTAssertEqual(store.orderedPlaylists().map(\.name), ["Alpha"])
    }

    func testCreateRejectsEmptyOrWhitespaceName() {
        let store = makeStore()
        store.load()
        XCTAssertThrowsError(try store.createPlaylist(name: "")) { err in
            XCTAssertEqual(err as? PlaylistStoreError, .emptyName)
        }
        XCTAssertThrowsError(try store.createPlaylist(name: "   ")) { err in
            XCTAssertEqual(err as? PlaylistStoreError, .emptyName)
        }
    }

    func testCreateRejectsDuplicateNameCaseInsensitive() throws {
        let store = makeStore()
        store.load()
        _ = try store.createPlaylist(name: "Mix")
        XCTAssertThrowsError(try store.createPlaylist(name: "mix")) { err in
            XCTAssertEqual(err as? PlaylistStoreError, .duplicateName)
        }
    }

    func testDeleteUnknownThrows() {
        let store = makeStore()
        store.load()
        XCTAssertThrowsError(try store.deletePlaylist(id: "missing")) { err in
            XCTAssertEqual(err as? PlaylistStoreError, .notFound)
        }
    }

    func testRenameAndDuplicateName() throws {
        let store = makeStore()
        store.load()
        let a = try store.createPlaylist(name: "A")
        _ = try store.createPlaylist(name: "B")
        XCTAssertThrowsError(try store.renamePlaylist(id: a.id, newName: "b")) { err in
            XCTAssertEqual(err as? PlaylistStoreError, .duplicateName)
        }
        try store.renamePlaylist(id: a.id, newName: "Renamed")
        XCTAssertEqual(store.orderedPlaylists().first { $0.id == a.id }?.name, "Renamed")
    }

    func testAddSongIdsDedupesAndPreservesOrder() throws {
        let store = makeStore()
        store.load()
        let pl = try store.createPlaylist(name: "P")
        try store.addSongIds(to: pl.id, songIds: ["s1", "s2"])
        try store.addSongIds(to: pl.id, songIds: ["s2", "s3"])
        XCTAssertEqual(store.playlist(id: pl.id)?.songIds, ["s1", "s2", "s3"])
    }

    func testRemoveSongIds() throws {
        let store = makeStore()
        store.load()
        let pl = try store.createPlaylist(name: "P")
        try store.addSongIds(to: pl.id, songIds: ["a", "b", "c"])
        try store.removeSongIds(from: pl.id, songIds: ["b"])
        XCTAssertEqual(store.playlist(id: pl.id)?.songIds, ["a", "c"])
    }

    func testSetSongOrderFiltersUnknownAndKeepsMissingAtEnd() throws {
        let store = makeStore()
        store.load()
        let pl = try store.createPlaylist(name: "P")
        try store.addSongIds(to: pl.id, songIds: ["x", "y", "z"])
        try store.setSongOrder(playlistId: pl.id, orderedIds: ["ghost", "z", "x"])
        XCTAssertEqual(store.playlist(id: pl.id)?.songIds, ["z", "x", "y"])
    }

    func testSetPlaylistOrder() throws {
        let store = makeStore()
        store.load()
        let p1 = try store.createPlaylist(name: "One")
        let p2 = try store.createPlaylist(name: "Two")
        XCTAssertEqual(store.orderedPlaylists().map(\.id), [p1.id, p2.id])
        try store.setPlaylistOrder(ids: [p2.id, p1.id])
        XCTAssertEqual(store.orderedPlaylists().map(\.id), [p2.id, p1.id])
    }

    func testPlaylistCodableRoundTrip() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let p = Playlist(id: "x", name: "N", songIds: ["a", "b"], createdAt: t, updatedAt: t)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Playlist.self, from: data)
        XCTAssertEqual(decoded, p)
    }
}
