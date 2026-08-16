import Foundation

/// Small in-memory LRU cache, generic over its stored value so the capacity/eviction policy — the
/// part that is genuinely worth unit-testing (see `ArtworkMemoryCacheTests.swift`) — has no
/// dependency on `UIImage` or any decode work.
///
/// Introduced to fix `WatchArtworkThumbnail` (`WatchSongListView.swift`): it used to do
/// `Data(contentsOf:)` + `UIImage(data:)` directly inside `body`, so every visible row re-read and
/// re-decoded its JPEG from disk on the main thread on *every* SwiftUI render pass — including
/// render passes triggered by unrelated `@Published` changes on `WatchAudioPlayerService`, since
/// every row observes it. The row now decodes off the main thread (see that view's doc comment) and
/// keeps the result here, keyed by song id, so a song already on screen is decoded once rather than
/// on every redraw or every re-appearance while scrolling.
///
/// A plain unbounded dictionary was rejected: a long library's worth of rows scrolled past over a
/// session would otherwise never release their decoded images. `NSCache` was also considered, but
/// its eviction is driven by an opaque, untestable system cost heuristic — unsuitable for the
/// "capacity/eviction policy must be unit-testable" requirement — so this is a small hand-rolled
/// LRU instead: eviction is deterministic (least-recently-used first) and directly testable.
///
/// Thread-safe via a plain lock (not an `actor`) so both the synchronous, main-actor read a SwiftUI
/// `body` needs and the off-main write after a background decode can go through the same instance
/// without an `await`.
final class ArtworkMemoryCache<Value>: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var storage: [String: Value] = [:]
    /// Keys ordered from least- to most-recently-used. The front is always the next eviction
    /// candidate.
    private var recencyOrder: [String] = []

    init(capacity: Int) {
        precondition(capacity > 0, "ArtworkMemoryCache capacity must be positive")
        self.capacity = capacity
    }

    /// Returns the cached value for `key`, marking it as most-recently-used so it survives eviction
    /// longer than entries that have not been read recently. `nil` if `key` was never stored or has
    /// since been evicted.
    func value(forKey key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[key] else { return nil }
        markMostRecentlyUsed(key)
        return value
    }

    /// Stores `value` for `key`, then evicts the least-recently-used entries until back at
    /// capacity. Overwriting an existing key updates its value and recency without growing `count`.
    func setValue(_ value: Value, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if storage[key] == nil {
            recencyOrder.append(key)
        } else {
            markMostRecentlyUsed(key)
        }
        storage[key] = value
        while recencyOrder.count > capacity {
            let oldest = recencyOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    /// Removes `key`'s entry, if present (e.g. the song was deleted from the library). No-op
    /// otherwise.
    func removeValue(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
        recencyOrder.removeAll { $0 == key }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    /// Caller must already hold `lock`.
    private func markMostRecentlyUsed(_ key: String) {
        if let index = recencyOrder.firstIndex(of: key) {
            recencyOrder.remove(at: index)
        }
        recencyOrder.append(key)
    }
}
