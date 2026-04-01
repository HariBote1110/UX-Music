import CryptoKit
import Foundation

/// Tracks downloaded song metadata and local `.m4a` paths (same role as Flutter `DownloadManager`).
@MainActor
final class DownloadManager {
    private(set) var downloadedSongs: [String: Song] = [:]
    private var documentsDirectory: URL
    private var tracksDirectory: URL
    private var artworkDirectory: URL

    init(fileManager: FileManager = .default) {
        documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        tracksDirectory = documentsDirectory.appendingPathComponent("DownloadedTracks", isDirectory: true)
        artworkDirectory = documentsDirectory.appendingPathComponent("DownloadedArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: tracksDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        loadMeta()
    }

    /// Flat file under `Documents/DownloadedTracks/` — never embed `songId` path segments (library ids can be full file paths).
    func localFileURL(songId: String) -> URL {
        tracksDirectory.appendingPathComponent(Self.storedFileName(for: songId))
    }

    func localPathString(songId: String) -> String {
        resolvedExistingFileURL(songId: songId)?.path ?? localFileURL(songId: songId).path
    }

    func isDownloaded(songId: String) -> Bool {
        guard downloadedSongs[songId] != nil else { return false }
        return resolvedExistingFileURL(songId: songId) != nil
    }

    func register(_ song: Song) {
        downloadedSongs[song.id] = song
        saveMeta()
    }

    func remove(songId: String) {
        downloadedSongs.removeValue(forKey: songId)
        if let u = resolvedExistingFileURL(songId: songId) {
            try? FileManager.default.removeItem(at: u)
        }
        saveMeta()
        pruneOrphanArtworkFiles()
    }

    /// On-disk path for a cached jacket image (JPEG/PNG/WebP bytes from Wear), keyed by `artworkId`.
    func localArtworkFileURLIfPresent(artworkId: String) -> URL? {
        guard !artworkId.isEmpty else { return nil }
        let u = artworkDirectory.appendingPathComponent(Self.artworkStorageFileName(for: artworkId))
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func hasLocalArtwork(artworkId: String) -> Bool {
        localArtworkFileURLIfPresent(artworkId: artworkId) != nil
    }

    /// Destination URL for a new download (parent directory must exist).
    func localArtworkDestinationURL(artworkId: String) -> URL {
        artworkDirectory.appendingPathComponent(Self.artworkStorageFileName(for: artworkId))
    }

    private func pruneOrphanArtworkFiles() {
        let needed = Set(
            downloadedSongs.values
                .filter { !$0.artworkId.isEmpty }
                .map { Self.artworkStorageFileName(for: $0.artworkId) }
        )
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: artworkDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for f in files where f.pathExtension.lowercased() == "img" {
            if !needed.contains(f.lastPathComponent) {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    private static func artworkStorageFileName(for artworkId: String) -> String {
        let digest = SHA256.hash(data: Data(artworkId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).img"
    }

    private func loadMeta() {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.downloadedSongsMetaKey),
              let list = try? JSONDecoder().decode([Song].self, from: data)
        else { return }

        let fm = FileManager.default
        let trackBasenames = Set(
            (try? fm.contentsOfDirectory(at: tracksDirectory, includingPropertiesForKeys: nil))?
                .map(\.lastPathComponent) ?? []
        )
        let docM4aBasenames = Set(
            (try? fm.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "m4a" }
                .map(\.lastPathComponent) ?? []
        )

        for song in list {
            let modernName = Self.storedFileName(for: song.id)
            if trackBasenames.contains(modernName) {
                downloadedSongs[song.id] = song
                continue
            }
            if Self.isSimpleLegacyFileStem(song.id), docM4aBasenames.contains("\(song.id).m4a") {
                downloadedSongs[song.id] = song
            }
        }
    }

    private func saveMeta() {
        let list = Array(downloadedSongs.values)
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: AppConstants.downloadedSongsMetaKey)
        }
    }

    private static func storedFileName(for songId: String) -> String {
        let digest = SHA256.hash(data: Data(songId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).m4a"
    }

    /// UUID-style keys used to live in `Documents/<id>.m4a` before path-shaped ids existed.
    private func legacyFlatFileURL(songId: String) -> URL? {
        guard Self.isSimpleLegacyFileStem(songId) else { return nil }
        return documentsDirectory.appendingPathComponent("\(songId).m4a")
    }

    private static func isSimpleLegacyFileStem(_ songId: String) -> Bool {
        if songId.isEmpty { return false }
        if songId.contains("/") || songId.contains("\\") { return false }
        if songId.contains(":") { return false }
        return true
    }

    private func resolvedExistingFileURL(songId: String) -> URL? {
        let modern = localFileURL(songId: songId)
        if FileManager.default.fileExists(atPath: modern.path) {
            return modern
        }
        if let leg = legacyFlatFileURL(songId: songId), FileManager.default.fileExists(atPath: leg.path) {
            return leg
        }
        return nil
    }
}
