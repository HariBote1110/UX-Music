import Foundation

/// Actor-isolated file-backed playback cache for Phase 1-4's pseudo-streaming (see
/// `markdown/appletv-servermode-plan.md` §1-4 and `progress/tvos-playback.md`). Files live under
/// `Caches/TVPlaybackCache/` — the OS may purge that directory under storage pressure, so this is
/// treated purely as a playback buffer, never surfaced to the UI as a "download".
///
/// LRU accounting/eviction *decisions* are pure (`TVPlaybackCachePlan`); this actor only performs
/// the actual disk I/O and keeps an open `FileHandle` on the currently-playing file so an OS purge
/// mid-song cannot unlink bytes out from under a playing `AVAudioFile` (see the file-handle note
/// on `pinCurrentlyPlaying(songId:)`).
actor TVPlaybackCacheStore {
    struct DownloadedFile: Sendable {
        let songId: String
        let fileURL: URL
    }

    private let directory: URL
    private let capacityBytes: Int64
    private let fileManager: FileManager
    private let downloader: @Sendable (String, URL) async throws -> Void

    /// Tracks last-access time per song id, independent of on-disk mtime (mtime is not bumped by
    /// reads, only writes — LRU needs read recency too).
    private var lastAccessedAt: [String: TimeInterval] = [:]
    /// Keeps a `FileHandle` open on the currently-playing file's inode so a concurrent eviction
    /// (or OS `Caches` purge) cannot make the bytes disappear mid-playback: on APFS/HFS+, an
    /// unlinked-but-open file's data survives until the last file descriptor closes. This does
    /// **not** protect against the *path* disappearing — anything that needs to re-open by path
    /// (e.g. `AVAudioFile` re-opened after a cold app relaunch) still needs the file to still
    /// exist on disk, so `pinCurrentlyPlaying` is a mitigation, not a guarantee.
    private var pinnedHandle: FileHandle?
    private var pinnedSongId: String?

    init(
        directory: URL,
        capacityBytes: Int64 = 2 * 1024 * 1024 * 1024,
        fileManager: FileManager = .default,
        downloader: @escaping @Sendable (String, URL) async throws -> Void
    ) {
        self.directory = directory
        self.capacityBytes = capacityBytes
        self.fileManager = fileManager
        self.downloader = downloader
    }

    /// Default cache directory: `Caches/TVPlaybackCache/` in the app's caches directory.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return caches.appendingPathComponent("TVPlaybackCache", isDirectory: true)
    }

    private func fileURL(for songId: String) -> URL {
        let safeName = songId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return directory.appendingPathComponent(safeName)
    }

    private func currentEntries() -> [TVCacheEntry] {
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        return items.compactMap { url -> TVCacheEntry? in
            guard let songId = url.lastPathComponent.removingPercentEncoding else { return nil }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            let accessedAt = lastAccessedAt[songId] ?? 0
            return TVCacheEntry(songId: songId, byteSize: size ?? 0, lastAccessedAt: accessedAt)
        }
    }

    /// Returns the cached file URL for `songId`, downloading it first if not already cached.
    /// `protectedSongIds` (typically the currently-playing + already-queued-for-prefetch ids)
    /// are never evicted to make room for this download.
    @discardableResult
    func ensureCached(songId: String, protectedSongIds: Set<String>) async throws -> DownloadedFile {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = fileURL(for: songId)

        if fileManager.fileExists(atPath: destination.path) {
            lastAccessedAt[songId] = Date().timeIntervalSince1970
            return DownloadedFile(songId: songId, fileURL: destination)
        }

        let toEvict = TVPlaybackCachePlan.entriesToEvict(
            existing: currentEntries(),
            incomingBytes: estimatedIncomingBytes,
            capacityBytes: capacityBytes,
            protectedSongIds: protectedSongIds
        )
        for evictSongId in toEvict {
            evict(songId: evictSongId)
        }

        try await downloader(songId, destination)
        lastAccessedAt[songId] = Date().timeIntervalSince1970
        return DownloadedFile(songId: songId, fileURL: destination)
    }

    /// Best-effort estimate used only for the eviction *headroom* check before a download starts
    /// (actual bytes are unknown until the download completes). Deliberately conservative — a
    /// modest fixed budget per pending download, not the true file size.
    private var estimatedIncomingBytes: Int64 { 64 * 1024 * 1024 }

    private func evict(songId: String) {
        guard pinnedSongId != songId else { return }
        try? fileManager.removeItem(at: fileURL(for: songId))
        lastAccessedAt.removeValue(forKey: songId)
    }

    /// Opens (and holds) a `FileHandle` on `songId`'s cached file so it survives concurrent
    /// eviction/purge while playing. Call once playback of that track actually starts; releases
    /// any previously pinned handle first.
    func pinCurrentlyPlaying(songId: String) {
        pinnedHandle = nil
        pinnedSongId = songId
        pinnedHandle = try? FileHandle(forReadingFrom: fileURL(for: songId))
    }

    func unpinCurrentlyPlaying() {
        pinnedHandle = nil
        pinnedSongId = nil
    }
}
