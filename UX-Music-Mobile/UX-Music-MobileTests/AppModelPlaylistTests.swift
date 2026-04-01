import XCTest
@testable import UX_Music_Mobile

@MainActor
final class AppModelPlaylistTests: XCTestCase {
    private func makeModelWithIsolatedPlaylists() -> AppModel {
        let suiteName = "test.appmodel.playlists.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("suite")
            fatalError()
        }
        defaults.removePersistentDomain(forName: suiteName)
        let store = PlaylistStore(defaults: defaults, persistenceKey: AppConstants.playlistsPersistenceKey)
        return AppModel(playlistStore: store)
    }

    func testCreatePlaylistUpdatesObservableList() throws {
        let model = makeModelWithIsolatedPlaylists()
        XCTAssertTrue(model.playlists.isEmpty)
        try model.createPlaylist(name: "Road trip")
        XCTAssertEqual(model.playlists.count, 1)
        XCTAssertEqual(model.playlists.first?.name, "Road trip")
    }

    func testResolvedSongsSkipsMissingDownloads() throws {
        let model = makeModelWithIsolatedPlaylists()
        let pl = try model.playlistStore.createPlaylist(name: "P")
        try model.playlistStore.addSongIds(to: pl.id, songIds: ["ghost", "real"])
        model.refreshPlaylists()
        let s = Song(id: "real", path: "/x", title: "T", artist: "A", album: "Al", albumArtist: "", artworkId: "art")
        model.downloadManager.register(s)
        let resolved = model.resolvedSongs(for: model.playlists[0])
        XCTAssertEqual(resolved.map(\.id), ["real"])
    }
}
