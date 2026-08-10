import CryptoKit
import Foundation

/// Tracks downloaded song metadata and flat files under `DownloadedTracks/` (same role as Flutter `DownloadManager`).
@MainActor
final class DownloadManager {
    private(set) var downloadedSongs: [String: Song] = [:]
    private var documentsDirectory: URL
    private var tracksDirectory: URL
    private var artworkDirectory: URL

    /// `stem` (sha256 of songId) -> resolved original-file URL under `tracksDirectory`. This is the
    /// in-memory replacement for what `resolvedExistingFileURL` used to compute by enumerating
    /// `tracksDirectory` on every call (measured O(n²) over a render pass of n rows — see
    /// `mobile_perf_research/notes/baseline-microbench-2026-08.md`). Built once in `init` (reusing
    /// `loadMeta`'s existing enumeration, so `init` still does exactly one directory listing) and kept
    /// in sync incrementally by every method that changes which original file exists for a stem:
    /// `finalizeDownloadedPart` (incl. `removeFinalisedTrackFiles`'s purge), `finalizeDownloadedAACPart`
    /// (via `finalizeDownloadedPart` on its `.storeAsOriginal` branch), `remove(songId:)`, and
    /// `register` (self-heal, see its doc comment).
    ///
    /// AAC-variant files (`<stem>_aac.m4a`) are deliberately NOT tracked here: `localAACVariantURLIfPresent`
    /// already does a single fixed-path `fileExists` check, which is already O(1) and needed no caching.
    ///
    /// The index never goes stale in practice: nothing outside this file writes into `tracksDirectory`
    /// (`WatchAudioTranscoder` writes into `Caches`, a different directory), so every original-file
    /// mutation flows through one of the methods above.
    private var resolvedFileURLByStem: [String: URL] = [:]

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
        resolvedFileURLByStem[stem] = dest
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
        let stem = Self.storedStem(for: song.id)
        if resolvedFileURLByStem[stem] == nil {
            // Self-heal: in production every download calls `finalizeDownloadedPart`/
            // `finalizeDownloadedAACPart` before `register`, so the index already has this stem and
            // this branch is a single dictionary lookup that does nothing. It only does real work
            // when a file was placed under `tracksDirectory` without going through those methods
            // (e.g. test fixtures that `Data.write` straight to `localFileURL(songId:)`) — a single
            // directory enumeration to pick the file up, not a per-call cost on the read path.
            if let match = Self.resolveOriginalFileURL(forStem: stem, in: tracksDirectory) {
                resolvedFileURLByStem[stem] = match
            }
        }
        saveMeta()
    }

    func remove(songId: String) {
        downloadedSongs.removeValue(forKey: songId)
        let stem = Self.storedStem(for: songId)
        if let u = resolvedExistingFileURL(songId: songId) {
            try? FileManager.default.removeItem(at: u)
        }
        if let aac = localAACVariantURLIfPresent(songId: songId) {
            try? FileManager.default.removeItem(at: aac)
        }
        resolvedFileURLByStem.removeValue(forKey: stem)
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
        // Single pass over `tracksDirectory`: builds `resolvedFileURLByStem` (the index that replaces
        // `resolvedExistingFileURL`'s former per-call enumeration) and, from the same listing, the
        // AAC-variant presence check below — so this optimisation adds no second enumeration here.
        let fm = FileManager.default
        let trackFiles =
            (try? fm.contentsOfDirectory(at: tracksDirectory, includingPropertiesForKeys: nil)) ?? []
        resolvedFileURLByStem = Self.buildResolvedFileURLByStem(from: trackFiles)

        guard let data = UserDefaults.standard.data(forKey: AppConstants.downloadedSongsMetaKey),
              let list = try? JSONDecoder().decode([Song].self, from: data)
        else { return }

        let docM4aBasenames = Set(
            (try? fm.contentsOfDirectory(at: documentsDirectory, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "m4a" }
                .map(\.lastPathComponent) ?? []
        )

        for song in list {
            let stem = Self.storedStem(for: song.id)
            if resolvedFileURLByStem[stem] != nil || Self.trackFilesContainAACVariant(trackFiles, stem: stem) {
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
        var removedAny = false
        for f in files {
            let name = f.lastPathComponent
            if name.hasPrefix("incomplete_") { continue }
            let base = f.deletingPathExtension().lastPathComponent
            if base == stem {
                try? FileManager.default.removeItem(at: f)
                removedAny = true
            }
        }
        if removedAny {
            resolvedFileURLByStem.removeValue(forKey: stem)
        }
    }

    /// Builds the `stem -> URL` index from a single `tracksDirectory` listing: excludes
    /// `incomplete_*.tmp` temp files and `<stem>_aac.m4a` variants (tracked separately, see
    /// `resolvedFileURLByStem`'s doc comment), and — matching the old per-call enumeration's tie-break —
    /// keeps the lexicographically smallest path when more than one file shares a stem.
    private static func buildResolvedFileURLByStem(from files: [URL]) -> [String: URL] {
        var candidatesByStem: [String: [URL]] = [:]
        for f in files {
            let name = f.lastPathComponent
            if name.hasPrefix("incomplete_") { continue }
            let base = f.deletingPathExtension().lastPathComponent
            if base.hasSuffix("_aac") { continue }
            candidatesByStem[base, default: []].append(f)
        }
        var result: [String: URL] = [:]
        for (stem, urls) in candidatesByStem {
            if let smallest = urls.min(by: { $0.path < $1.path }) {
                result[stem] = smallest
            }
        }
        return result
    }

    /// Single-stem variant of `buildResolvedFileURLByStem`, used by `register`'s self-heal path where
    /// only one stem's presence needs resolving (see `resolvedFileURLByStem`'s doc comment).
    private static func resolveOriginalFileURL(forStem stem: String, in directory: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let matches = files.filter { f in
            let name = f.lastPathComponent
            if name.hasPrefix("incomplete_") { return false }
            return f.deletingPathExtension().lastPathComponent == stem
        }
        return matches.min(by: { $0.path < $1.path })
    }

    /// True when `stem_aac.m4a` (the AAC-only variant) is present in an already-fetched directory
    /// listing — an AAC-only song must still survive `loadMeta` on relaunch even though it has no
    /// `stem.*` original file.
    private static func trackFilesContainAACVariant(_ files: [URL], stem: String) -> Bool {
        let variantBase = "\(stem)_aac"
        return files.contains { f in
            let name = f.lastPathComponent
            if name.hasPrefix("incomplete_") { return false }
            return f.deletingPathExtension().lastPathComponent == variantBase
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

    /// O(1) dictionary lookup (formerly a full `tracksDirectory` enumeration on every call — the
    /// measured O(n²) source, see `resolvedFileURLByStem`'s doc comment). No per-hit `fileExists`
    /// re-verification: the index is kept in sync by every method that mutates `tracksDirectory`, and
    /// nothing else touches that directory, so a hit here is never stale.
    ///
    /// The legacy `Documents/<id>.m4a` fallback stays a direct filesystem check — it only applies to
    /// UUID-style ids without `stem.*`/`_aac` files (see `isSimpleLegacyFileStem`), a rare, bounded path.
    private func resolvedExistingFileURL(songId: String) -> URL? {
        let stem = Self.storedStem(for: songId)
        if let cached = resolvedFileURLByStem[stem] {
            return cached
        }
        if let leg = legacyFlatFileURL(songId: songId), FileManager.default.fileExists(atPath: leg.path) {
            return leg
        }
        return nil
    }
}
