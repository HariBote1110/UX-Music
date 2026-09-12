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
    private var isLoading = false
    private var mutationRevision = 0

    nonisolated fileprivate static var indexFileURL: URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDir.appendingPathComponent("playlists.json")
    }

    init() {
    }

    /// Replaces the whole playlist index — the iPhone always sends its complete playlist set (there
    /// is no per-playlist add/remove transfer), so "replace wholesale" is the correct merge
    /// semantics here, unlike `WatchLibraryIndex.adding` for individual songs.
    func replaceAll(_ newPlaylists: [WatchPlaylistMeta]) {
        mutationRevision += 1
        playlists = newPlaylists
        if !isLoading {
            saveToDisk()
        }
    }

    func reload() {
        #if DEBUG
        WatchPerfBreadcrumb.mark("playlistLibrary.reload.begin")
        #endif
        Task { @MainActor in
            await reloadAndWait()
        }
    }

    func reloadAndWait() async {
        isLoading = true
        let startingRevision = mutationRevision
        #if DEBUG
        WatchPerfBreadcrumb.mark("playlistLibrary.reload.detached.begin")
        #endif
        let loaded = await Task.detached(priority: .utility) { () -> [WatchPlaylistMeta] in
            Self.readFromDisk()
        }.value
        guard !Task.isCancelled else {
            isLoading = false
            return
        }
        let didMutateDuringLoad = mutationRevision != startingRevision
        if !didMutateDuringLoad {
            playlists = loaded
        }
        isLoading = false
        #if DEBUG
        WatchPerfBreadcrumb.mark("playlistLibrary.reload.publish.end")
        #endif
        if didMutateDuringLoad {
            saveToDisk()
        }
    }

    nonisolated private static func readFromDisk() -> [WatchPlaylistMeta] {
        #if DEBUG
        WatchPerfBreadcrumb.mark("playlistLibrary.readDisk.begin")
        #endif
        guard
            let data = try? Data(contentsOf: Self.indexFileURL),
            let decoded = try? JSONDecoder().decode([WatchPlaylistMeta].self, from: data)
        else {
            #if DEBUG
            WatchPerfBreadcrumb.mark("playlistLibrary.readDisk.end")
            #endif
            return []
        }
        #if DEBUG
        WatchPerfBreadcrumb.mark("playlistLibrary.readDisk.end")
        #endif
        return decoded
    }

    private func saveToDisk() {
        WatchPlaylistDiskWriter.shared.enqueue(playlists)
    }
}

private enum WatchPlaylistDiskWriter {
    static let shared = WatchCoalescingJSONWriter<[WatchPlaylistMeta]>(
        label: "UXMusicWatch.playlistDiskWriter",
        fileURL: { WatchPlaylistLibrary.indexFileURL }
    )
}
