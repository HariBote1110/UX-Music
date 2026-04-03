import CryptoKit
import Foundation

/// Tracks downloaded song metadata and flat files under `DownloadedTracks/` (same role as Flutter `DownloadManager`).
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

    /// Temp path for `URLSession` while downloading (not a `stem.*` track file — see `finalizeDownloadedPart`).
    func temporaryDownloadURL(songId: String) -> URL {
        tracksDirectory.appendingPathComponent("incomplete_\(Self.storedStem(for: songId)).tmp")
    }

    /// After a successful HTTP download into `temporaryDownloadURL`, sniff bytes and move to `stem.<ext>`.
    func finalizeDownloadedPart(at tempURL: URL, song: Song) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: tempURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let head = try Self.readFileHead(url: tempURL, maxBytes: 64)
        let ext = DownloadedTrackFormatSniffer.preferredExtension(
            header: head,
            libraryPath: song.path,
            fileType: song.fileType
        )
        let stem = Self.storedStem(for: song.id)
        removeFinalisedTrackFiles(forStem: stem)
        let dest = tracksDirectory.appendingPathComponent("\(stem).\(ext)")
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tempURL, to: dest)
    }

    /// Hypothetical `.m4a` path when no resolved file exists (legacy callers / tests).
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
        let trackNames =
            (try? fm.contentsOfDirectory(at: tracksDirectory, includingPropertiesForKeys: nil))?
                .map(\.lastPathComponent) ?? []
        let docM4aBasenames = Set(
            (try? fm.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "m4a" }
                .map(\.lastPathComponent) ?? []
        )

        for song in list {
            let stem = Self.storedStem(for: song.id)
            if Self.trackListContainsStem(trackNames, stem: stem) {
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

    /// Legacy on-disk name `sha256(songId).m4a` (actual file may use another extension after sniffing).
    private static func storedFileName(for songId: String) -> String {
        "\(storedStem(for: songId)).m4a"
    }

    private static func storedStem(for songId: String) -> String {
        let digest = SHA256.hash(data: Data(songId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func readFileHead(url: URL, maxBytes: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return (try h.read(upToCount: maxBytes)) ?? Data()
    }

    private func removeFinalisedTrackFiles(forStem stem: String) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: tracksDirectory, includingPropertiesForKeys: nil) else { return }
        for f in files {
            let name = f.lastPathComponent
            if name.hasPrefix("incomplete_") { continue }
            let base = f.deletingPathExtension().lastPathComponent
            if base == stem {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    private static func trackListContainsStem(_ names: [String], stem: String) -> Bool {
        names.contains { name in
            guard !name.hasPrefix("incomplete_") else { return false }
            let base = (name as NSString).deletingPathExtension
            return base == stem
        }
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
        let stem = Self.storedStem(for: songId)
        guard let files = try? FileManager.default.contentsOfDirectory(at: tracksDirectory, includingPropertiesForKeys: nil) else { return nil }
        let matches = files.filter { f in
            let name = f.lastPathComponent
            if name.hasPrefix("incomplete_") { return false }
            return f.deletingPathExtension().lastPathComponent == stem
        }
        if let u = matches.sorted(by: { $0.path < $1.path }).first {
            return u
        }
        if let leg = legacyFlatFileURL(songId: songId), FileManager.default.fileExists(atPath: leg.path) {
            return leg
        }
        return nil
    }
}
