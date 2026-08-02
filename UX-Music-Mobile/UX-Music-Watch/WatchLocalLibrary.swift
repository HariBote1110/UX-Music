import Foundation

/// Persisted index of songs received from the iPhone, stored under Application Support as JSON
/// (`library.json`). Merge/remove semantics live in `WatchLibraryIndex` (shared, pure, tested from
/// the iOS test target); this class only owns the on-disk read/write and the audio file lifecycle.
@MainActor
final class WatchLocalLibrary: ObservableObject {

    @Published private(set) var songs: [WatchTransferMeta] = []

    private let indexFileURL: URL
    private let audioDirectory: URL

    static let shared = WatchLocalLibrary()

    init(fileManager: FileManager = .default) {
        let supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        indexFileURL = supportDir.appendingPathComponent("library.json")
        audioDirectory = supportDir.appendingPathComponent("Audio", isDirectory: true)
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    /// Destination URL for a song's audio asset (used by the receiver to move the transferred file
    /// into place, and by the player to load it).
    func audioFileURL(for meta: WatchTransferMeta) -> URL {
        audioDirectory.appendingPathComponent(meta.storedFileName)
    }

    /// Registers a newly received song whose audio file has already been moved to
    /// `audioFileURL(for:)`. No-op if the id is already present (see `WatchLibraryIndex.adding`).
    func addSong(_ meta: WatchTransferMeta) {
        songs = WatchLibraryIndex.adding(meta, to: songs)
        saveToDisk()
    }

    /// Removes the song's index entry and deletes its audio file.
    func removeSong(id: String) {
        guard let meta = songs.first(where: { $0.id == id }) else { return }
        songs = WatchLibraryIndex.removing(id: id, from: songs)
        saveToDisk()
        try? FileManager.default.removeItem(at: audioFileURL(for: meta))
    }

    private func loadFromDisk() {
        guard
            let data = try? Data(contentsOf: indexFileURL),
            let decoded = try? JSONDecoder().decode([WatchTransferMeta].self, from: data)
        else { return }
        songs = WatchLibraryIndex.retainingExistingFiles(decoded) { meta in
            FileManager.default.fileExists(atPath: self.audioFileURL(for: meta).path)
        }
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(songs) else { return }
        try? data.write(to: indexFileURL, options: .atomic)
    }
}
