import XCTest
@testable import UX_Music_Mobile

@MainActor
final class CollectionShufflePreferenceTests: XCTestCase {
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "CollectionShufflePreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testPreferencePersistsAndCanBeCleared() {
        let fixture = makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let reference = PlaybackCollectionRef(kind: .album, key: "album-id")

        let store = CollectionShufflePreferenceStore(defaults: fixture.defaults)
        store.setPreference(.on, for: reference)

        let reloaded = CollectionShufflePreferenceStore(defaults: fixture.defaults)
        XCTAssertEqual(reloaded.preference(for: reference), .on)

        reloaded.setPreference(nil, for: reference)
        XCTAssertNil(CollectionShufflePreferenceStore(defaults: fixture.defaults).preference(for: reference))
    }

    func testDeletingLocalPlaylistClearsItsPreference() throws {
        let fixture = makeDefaults()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let preferences = CollectionShufflePreferenceStore(defaults: fixture.defaults)
        let playlists = PlaylistStore(
            defaults: fixture.defaults,
            persistenceKey: "test.playlists.\(UUID().uuidString)",
            collectionShufflePreferenceStore: preferences
        )
        let playlist = try playlists.createPlaylist(name: "Road trip")
        let reference = PlaybackCollectionRef(kind: .playlist, key: playlist.id)
        preferences.setPreference(.off, for: reference)

        try playlists.deletePlaylist(id: playlist.id)

        XCTAssertNil(preferences.preference(for: reference))
    }

    func testEffectiveShuffleUsesCollectionPreferenceWhenPresent() {
        XCTAssertTrue(
            PlaybackCollectionShuffleLogic.effectiveShuffleEnabled(
                baselineShuffleEnabled: false,
                preference: .on
            )
        )
        XCTAssertFalse(
            PlaybackCollectionShuffleLogic.effectiveShuffleEnabled(
                baselineShuffleEnabled: true,
                preference: .off
            )
        )
        XCTAssertTrue(
            PlaybackCollectionShuffleLogic.effectiveShuffleEnabled(
                baselineShuffleEnabled: true,
                preference: nil
            )
        )
    }
}
