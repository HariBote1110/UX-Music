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

    /// AAC variant path for `songId` (`<stem>_aac.m4a`), stored alongside the original when
    /// `DownloadAudioQuality.aac`/`.both` is used. Deliberately outside `resolvedExistingFileURL`'s
    /// `base == stem` match, so it stays invisible to the original-file resolution logic — any
    /// combination of the two files is valid regardless of the current setting.
    func aacVariantDestinationURL(songId: String) -> URL {
        tracksDirectory.appendingPathComponent("\(Self.storedStem(for: songId))_aac.m4a")
    }

    /// The AAC variant file if one was downloaded and stored, `nil` otherwise.
    func localAACVariantURLIfPresent(songId: String) -> URL? {
        let url = aacVariantDestinationURL(songId: songId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// After a successful "AAC" HTTP download (`DownloadAudioQuality.aac`/`.both`) into
    /// `temporaryDownloadURL`, sniffs the header and applies `AACVariantFinalisePlan`: the desktop
    /// server falls back to serving ORIGINAL bytes when its ffmpeg is unavailable, so what was
    /// requested as AAC may actually be the original file's bytes.
    func finalizeDownloadedAACPart(at tempURL: URL, song: Song) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: tempURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let head = try Self.readFileHead(url: tempURL, maxBytes: 64)
        let sniffedExt = DownloadedTrackFormatSniffer.preferredExtension(
            header: head,
            libraryPath: song.path,
            fileType: song.fileType
        )
        let plan = AACVariantFinalisePlan.plan(
            sniffedExtension: sniffedExt,
            originalAlreadyPresent: resolvedExistingFileURL(songId: song.id) != nil
        )
        switch plan {
        case .storeAsVariant:
            let dest = aacVariantDestinationURL(songId: song.id)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: tempURL, to: dest)
        case .storeAsOriginal:
            try finalizeDownloadedPart(at: tempURL, song: song)
        case .discard:
            try? fm.removeItem(at: tempURL)
        }
    }

    /// Hypothetical `.m4a` path when no resolved file exists (legacy callers / tests).
    func localFileURL(songId: String) -> URL {
        tracksDirectory.appendingPathComponent(Self.storedFileName(for: songId))
    }

    /// Full-quality original if present, else the AAC variant, else the (possibly non-existent)
    /// legacy `.m4a` path — playback always prefers full quality when both files exist.
    func localPathString(songId: String) -> String {
        if let original = resolvedExistingFileURL(songId: songId) { return original.path }
        if let aac = localAACVariantURLIfPresent(songId: songId) { return aac.path }
        return localFileURL(songId: songId).path
    }

    /// The file `WatchTransferBridge` should send: the AAC variant when present (already the right
    /// size/format for the Watch, so `WatchTransferAudioPolicy` skips on-device transcoding
    /// entirely), otherwise the resolved original, otherwise `nil` when nothing is downloaded.
    func watchTransferSourceURL(songId: String) -> URL? {
        localAACVariantURLIfPresent(songId: songId) ?? resolvedExistingFileURL(songId: songId)
    }

    func isDownloaded(songId: String) -> Bool {
        guard downloadedSongs[songId] != nil else { return false }
        return resolvedExistingFileURL(songId: songId) != nil || localAACVariantURLIfPresent(songId: songId) != nil
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
        if let aac = localAACVariantURLIfPresent(songId: songId) {
            try? FileManager.default.removeItem(at: aac)
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

    /// True when `stem.*` (the original) or `stem_aac.m4a` (the AAC-only variant) is present — an
    /// AAC-only song must still survive `loadMeta` on relaunch even though it has no `stem.*` file.
    private static func trackListContainsStem(_ names: [String], stem: String) -> Bool {
        names.contains { name in
            guard !name.hasPrefix("incomplete_") else { return false }
            let base = (name as NSString).deletingPathExtension
            return base == stem || base == "\(stem)_aac"
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
