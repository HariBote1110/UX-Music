import Foundation

/// Storage locations for the Watch-side library, kept as plain (non-actor-isolated) computation so
/// they can be resolved from the WatchConnectivity delegate callback — which arrives on a background
/// queue — without first hopping to the main actor. `WCSessionFile.fileURL` is only guaranteed valid
/// for the duration of that callback, so the destination path (and the copy itself) must be
/// resolvable synchronously from a nonisolated context; only the `@Published` index update needs to
/// happen on the main actor.
enum WatchAudioStorage {
    static let audioDirectory: URL = {
        let fileManager = FileManager.default
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDir.appendingPathComponent("Audio", isDirectory: true)
    }()

    static let artworkDirectory: URL = {
        let fileManager = FileManager.default
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDir.appendingPathComponent("Artwork", isDirectory: true)
    }()

    static var indexFileURL: URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDir.appendingPathComponent("library.json")
    }

    static func ensureDirectories() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
    }

    /// Destination URL for a song's audio asset (used by the receiver to move the transferred file
    /// into place, and by the player to load it). Pure given `meta` — safe to call from any thread.
    static func audioFileURL(for meta: WatchTransferMeta) -> URL {
        audioDirectory.appendingPathComponent(meta.storedFileName)
    }

    /// Destination URL for a song's downscaled artwork JPEG, resolved from `id` alone (not from
    /// `WatchTransferMeta.artworkFileName`) so the receiver can save it without needing the full
    /// song metadata — see `WatchTransferMeta.storedArtworkFileName(forId:)`.
    static func artworkFileURL(forId id: String) -> URL {
        artworkDirectory.appendingPathComponent(WatchTransferMeta.storedArtworkFileName(forId: id))
    }
}

/// Persisted index of songs received from the iPhone, stored under Application Support as JSON
/// (`library.json`). Merge/remove semantics live in `WatchLibraryIndex` (shared, pure, tested from
/// the iOS test target); this class only owns the on-disk read/write and the audio file lifecycle.
@MainActor
final class WatchLocalLibrary: ObservableObject {

    @Published private(set) var songs: [WatchTransferMeta] = []

    /// The flat "Songs" list's album-sorted order plus per-row connector positions (see
    /// `WatchFlatSongOrder`), and the "Albums" browse mode's per-album grouping (see
    /// `WatchAlbumGrouping.albums(from:)`) — both derived from `songs` and recomputed exactly once
    /// by `setSongs(_:)` whenever `songs` actually changes, rather than inline inside
    /// `WatchSongListView`'s body. That view used to call `WatchAlbumGrouping.songsSortedByAlbum`/
    /// `AlbumGrouping.positions(forAlbumKeys:)`/`WatchAlbumGrouping.albums(from:)` itself on every
    /// body evaluation — including evaluations triggered by `NavigationLink(destination:label:)`
    /// eagerly building its destination as soon as the Library page's row appears, well before the
    /// user actually taps into either list (confirmed by instrumented counts while running the app
    /// — see `progress/watch-ui-redesign.md`).
    @Published private(set) var flatOrder: WatchFlatSongOrder = .empty
    @Published private(set) var albums: [WatchAlbumGroup] = []

    private var isLoading = false
    private var mutationRevision = 0
    private var pendingSongChanges: [String: WatchTransferMeta] = [:]
    private var pendingRemovedSongIDs: Set<String> = []

    static let shared = WatchLocalLibrary()

    init(fileManager: FileManager = .default) {
        _ = fileManager
    }

    /// Destination URL for a song's audio asset (used by the receiver to move the transferred file
    /// into place, and by the player to load it).
    func audioFileURL(for meta: WatchTransferMeta) -> URL {
        WatchAudioStorage.audioFileURL(for: meta)
    }

    /// URL for a song's cached artwork JPEG, if one has been received — `nil` if no artwork has
    /// been transferred for this song yet (e.g. it was sent before artwork support existed;
    /// re-sending from the iPhone will fill it in).
    func artworkFileURLIfPresent(for meta: WatchTransferMeta) -> URL? {
        let url = WatchAudioStorage.artworkFileURL(forId: meta.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Registers a newly received song whose audio file has already been moved to
    /// `audioFileURL(for:)`. No-op if the id is already present (see `WatchLibraryIndex.adding`).
    func addSong(_ meta: WatchTransferMeta) {
        mutationRevision += 1
        if isLoading {
            pendingSongChanges[meta.id] = meta
            pendingRemovedSongIDs.remove(meta.id)
            return
        }
        setSongs(WatchLibraryIndex.adding(meta, to: songs))
        saveToDisk()
    }

    /// Removes the song's index entry and deletes its audio file.
    func removeSong(id: String) {
        let meta = songs.first(where: { $0.id == id }) ?? pendingSongChanges[id]
        if isLoading {
            mutationRevision += 1
            pendingSongChanges.removeValue(forKey: id)
            pendingRemovedSongIDs.insert(id)
            deleteAudioFile(for: id, meta: meta)
            return
        }
        guard let meta else { return }
        mutationRevision += 1
        setSongs(WatchLibraryIndex.removing(id: id, from: songs))
        saveToDisk()
        deleteAudioFile(for: id, meta: meta)
    }

    /// Deletes a received audio asset without making the main actor perform filesystem work. When
    /// a removal arrives during the initial index load, the full metadata may not be in memory yet,
    /// so fall back to the filesystem-safe id stem and remove any matching audio extension.
    private func deleteAudioFile(for id: String, meta: WatchTransferMeta?) {
        let knownURL = meta.map(audioFileURL(for:))
        let storageStem = WatchTransferMeta.storageStem(for: id)
        DispatchQueue(label: "UXMusicWatch.libraryAssetDeletion", qos: .utility).async {
            #if DEBUG
            WatchPerfBreadcrumb.mark("library.removeAudioFile.begin")
            #endif
            if let knownURL {
                try? FileManager.default.removeItem(at: knownURL)
            } else if let urls = try? FileManager.default.contentsOfDirectory(
                at: WatchAudioStorage.audioDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for url in urls where url.deletingPathExtension().lastPathComponent == storageStem {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            #if DEBUG
            WatchPerfBreadcrumb.mark("library.removeAudioFile.end")
            #endif
        }
    }

    /// Re-reads the on-disk index, e.g. when the app returns to the foreground. Cheap and
    /// idempotent — mirrors `loadFromDisk()` at init but is safe to call again at any time.
    func reload() {
        #if DEBUG
        WatchPerfBreadcrumb.mark("library.reload.begin")
        #endif
        Task { @MainActor in
            await reloadAndWait()
        }
    }

    /// Loads the index and all derived collections off the main actor, then publishes one coherent
    /// snapshot. Callers that need the songs (notably resume restoration) await this method.
    func reloadAndWait() async {
        isLoading = true
        let startingRevision = mutationRevision
        #if DEBUG
        WatchPerfBreadcrumb.mark("library.reload.detached.begin")
        #endif
        let snapshot = await Task.detached(priority: .utility) { () -> WatchLibraryDiskSnapshot in
            Self.readFromDisk()
        }.value
        guard !Task.isCancelled else {
            isLoading = false
            pendingSongChanges.removeAll()
            pendingRemovedSongIDs.removeAll()
            return
        }
        let didMutateDuringLoad = mutationRevision != startingRevision
        var finalSnapshot = snapshot
        if didMutateDuringLoad {
            var merged = snapshot.songs.filter { !pendingRemovedSongIDs.contains($0.id) }
            for meta in pendingSongChanges.values {
                if let index = merged.firstIndex(where: { $0.id == meta.id }) {
                    merged[index] = meta
                } else {
                    merged.append(meta)
                }
            }
            finalSnapshot = .computed(from: merged)
        }
        isLoading = false
        pendingSongChanges.removeAll()
        pendingRemovedSongIDs.removeAll()
        #if DEBUG
        WatchPerfBreadcrumb.mark("library.reload.publish.begin")
        #endif
        songs = finalSnapshot.songs
        flatOrder = finalSnapshot.flatOrder
        albums = finalSnapshot.albums
        #if DEBUG
        WatchPerfBreadcrumb.mark("library.reload.publish.end")
        #endif
        if didMutateDuringLoad {
            saveToDisk()
        }
    }

    nonisolated private static func readFromDisk() -> WatchLibraryDiskSnapshot {
        #if DEBUG
        WatchPerfBreadcrumb.mark("library.readDisk.begin")
        #endif
        WatchAudioStorage.ensureDirectories()
        guard
            let data = try? Data(contentsOf: WatchAudioStorage.indexFileURL),
            let decoded = try? JSONDecoder().decode([WatchTransferMeta].self, from: data)
        else {
            #if DEBUG
            WatchPerfBreadcrumb.mark("library.readDisk.end")
            #endif
            return .empty
        }
        let songs = WatchLibraryIndex.retainingExistingFiles(decoded) { meta in
            let url = WatchAudioStorage.audioFileURL(for: meta)
            return FileManager.default.fileExists(atPath: url.path)
        }
        let snapshot = WatchLibraryDiskSnapshot(
            songs: songs,
            flatOrder: WatchFlatSongOrder.computed(from: songs),
            albums: WatchAlbumGrouping.albums(from: songs)
        )
        #if DEBUG
        WatchPerfBreadcrumb.mark("library.readDisk.end")
        #endif
        return snapshot
    }

    /// Single choke point for updating `songs`: also refreshes the derived `flatOrder`/`albums`
    /// caches in the same step, so they can never go stale relative to `songs` and are computed
    /// exactly once per actual change (see the doc comment on `flatOrder`).
    private func setSongs(_ newSongs: [WatchTransferMeta]) {
        songs = newSongs
        flatOrder = WatchFlatSongOrder.computed(from: newSongs)
        albums = WatchAlbumGrouping.albums(from: newSongs)
    }

    private func saveToDisk() {
        WatchLibraryDiskWriter.shared.enqueue(songs)
    }
}

private struct WatchLibraryDiskSnapshot: Sendable {
    let songs: [WatchTransferMeta]
    let flatOrder: WatchFlatSongOrder
    let albums: [WatchAlbumGroup]

    static let empty = WatchLibraryDiskSnapshot(
        songs: [],
        flatOrder: .empty,
        albums: []
    )

    static func computed(from songs: [WatchTransferMeta]) -> WatchLibraryDiskSnapshot {
        WatchLibraryDiskSnapshot(
            songs: songs,
            flatOrder: WatchFlatSongOrder.computed(from: songs),
            albums: WatchAlbumGrouping.albums(from: songs)
        )
    }
}
private enum WatchLibraryDiskWriter {
    static let shared = WatchCoalescingJSONWriter<[WatchTransferMeta]>(
        label: "UXMusicWatch.libraryDiskWriter",
        fileURL: { WatchAudioStorage.indexFileURL }
    )
}
