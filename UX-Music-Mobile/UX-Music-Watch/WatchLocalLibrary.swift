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
        let dir = supportDir.appendingPathComponent("Audio", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let artworkDirectory: URL = {
        let fileManager = FileManager.default
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = supportDir.appendingPathComponent("Artwork", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var indexFileURL: URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDir.appendingPathComponent("library.json")
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

    static let shared = WatchLocalLibrary()

    init(fileManager: FileManager = .default) {
        _ = WatchAudioStorage.audioDirectory // ensure the directory exists before first use
        loadFromDisk()
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
        setSongs(WatchLibraryIndex.adding(meta, to: songs))
        saveToDisk()
    }

    /// Removes the song's index entry and deletes its audio file.
    func removeSong(id: String) {
        guard let meta = songs.first(where: { $0.id == id }) else { return }
        setSongs(WatchLibraryIndex.removing(id: id, from: songs))
        saveToDisk()
        try? FileManager.default.removeItem(at: audioFileURL(for: meta))
    }

    /// Re-reads the on-disk index, e.g. when the app returns to the foreground. Cheap and
    /// idempotent — mirrors `loadFromDisk()` at init but is safe to call again at any time.
    func reload() {
        loadFromDisk()
    }

    private func loadFromDisk() {
        guard
            let data = try? Data(contentsOf: WatchAudioStorage.indexFileURL),
            let decoded = try? JSONDecoder().decode([WatchTransferMeta].self, from: data)
        else { return }
        setSongs(WatchLibraryIndex.retainingExistingFiles(decoded) { meta in
            FileManager.default.fileExists(atPath: self.audioFileURL(for: meta).path)
        })
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
        guard let data = try? JSONEncoder().encode(songs) else { return }
        try? data.write(to: WatchAudioStorage.indexFileURL, options: .atomic)
    }
}
