import Foundation

/// One cached playback file's bookkeeping. `byteSize`/`lastAccessedAt` drive LRU eviction;
/// the actual bytes live under `Caches/` (see `TVPlaybackCacheStore`).
struct TVCacheEntry: Equatable, Sendable {
    let songId: String
    let byteSize: Int64
    let lastAccessedAt: TimeInterval
}

/// Pure LRU eviction planning for the tvOS playback cache (Phase 1-4). Kept free of
/// `FileManager`/actors so the eviction rule itself — "evict least-recently-accessed first,
/// but never the currently-playing (or otherwise protected) track, until the incoming file
/// fits under the capacity" — is unit-testable without touching disk.
enum TVPlaybackCachePlan {
    /// Returns the ids of `existing` entries to evict, oldest-`lastAccessedAt`-first, stopping
    /// as soon as `existing bytes − evicted bytes + incomingBytes <= capacityBytes` (or once no
    /// evictable — i.e. unprotected — entries remain, whichever comes first).
    static func entriesToEvict(
        existing: [TVCacheEntry],
        incomingBytes: Int64,
        capacityBytes: Int64,
        protectedSongIds: Set<String>
    ) -> [String] {
        let currentTotal = existing.reduce(Int64(0)) { $0 + $1.byteSize }
        var overflow = currentTotal + incomingBytes - capacityBytes
        guard overflow > 0 else { return [] }

        let evictable = existing
            .filter { !protectedSongIds.contains($0.songId) }
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }

        var evicted: [String] = []
        for entry in evictable {
            guard overflow > 0 else { break }
            evicted.append(entry.songId)
            overflow -= entry.byteSize
        }
        return evicted
    }
}
