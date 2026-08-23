import Foundation

/// Persisted index of playlists received from the iPhone, stored under Application Support as JSON
/// (`playlists.json`) — the playlist analogue of `WatchLocalLibrary`'s `library.json`. Unlike songs,
/// playlists carry no separate on-disk asset of their own (just the ids referenced in
/// `WatchPlaylistMeta.songIds`), so this type is simpler: one JSON array, replaced wholesale on
/// every transfer rather than merged entry-by-entry.
///
/// See `WatchConnectivityReceiver`'s doc comment for how a playlist transfer actually arrives.
@MainActor
final class WatchPlaylistLibrary: ObservableObject {

    @Published private(set) var playlists: [WatchPlaylistMeta] = []

    private static var indexFileURL: URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDir.appendingPathComponent("playlists.json")
    }

    init() {
        loadFromDisk()
    }

    /// Replaces the whole playlist index — the iPhone always sends its complete playlist set (there
    /// is no per-playlist add/remove transfer), so "replace wholesale" is the correct merge
    /// semantics here, unlike `WatchLibraryIndex.adding` for individual songs.
    func replaceAll(_ newPlaylists: [WatchPlaylistMeta]) {
        playlists = newPlaylists
        saveToDisk()
    }

    private func loadFromDisk() {
        guard
            let data = try? Data(contentsOf: Self.indexFileURL),
            let decoded = try? JSONDecoder().decode([WatchPlaylistMeta].self, from: data)
        else { return }
        playlists = decoded
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: Self.indexFileURL, options: .atomic)
    }
}
