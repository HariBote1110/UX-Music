import Foundation

/// Pure prefetch planning for Phase 1-4's pseudo-streaming playback (see
/// `markdown/appletv-servermode-plan.md` §1-4): the current track plus the next
/// `prefetchCount` queue entries are downloaded ahead of playback. No networking or
/// file I/O here — `TVPlaybackController` drives the actual downloads with this list.
enum TVPrefetchPlanner {
    /// Returns song ids to have ready in the cache, in priority order (current track first).
    /// Does not wrap around the end of the queue — Phase 1 has no TV-side repeat/shuffle
    /// prefetch beyond the visible queue tail.
    static func songIdsToPrefetch(queue: [Song], currentIndex: Int, prefetchCount: Int = 2) -> [String] {
        guard queue.indices.contains(currentIndex) else { return [] }
        let end = min(queue.count, currentIndex + 1 + max(0, prefetchCount))
        return queue[currentIndex..<end].map(\.id)
    }
}
