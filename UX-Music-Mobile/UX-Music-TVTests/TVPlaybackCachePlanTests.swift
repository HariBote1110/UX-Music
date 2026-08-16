import XCTest
@testable import UX_Music_TV

final class TVPlaybackCachePlanTests: XCTestCase {
    private func entry(_ id: String, bytes: Int64, lastAccess: TimeInterval) -> TVCacheEntry {
        TVCacheEntry(songId: id, byteSize: bytes, lastAccessedAt: lastAccess)
    }

    func testNoEvictionNeededWhenUnderCapacity() {
        let entries = [entry("a", bytes: 10, lastAccess: 1), entry("b", bytes: 10, lastAccess: 2)]
        let plan = TVPlaybackCachePlan.entriesToEvict(
            existing: entries,
            incomingBytes: 5,
            capacityBytes: 100,
            protectedSongIds: []
        )
        XCTAssertEqual(plan, [])
    }

    func testEvictsLeastRecentlyAccessedFirst() {
        let entries = [
            entry("a", bytes: 40, lastAccess: 1),
            entry("b", bytes: 40, lastAccess: 3),
            entry("c", bytes: 40, lastAccess: 2),
        ]
        // capacity 120 (== current total), incoming 40 -> exactly the oldest entry's 40 bytes
        // must be freed; "a" (lastAccess 1) goes before "c" (2) and "b" (3).
        let plan = TVPlaybackCachePlan.entriesToEvict(
            existing: entries,
            incomingBytes: 40,
            capacityBytes: 120,
            protectedSongIds: []
        )
        XCTAssertEqual(plan, ["a"])
    }

    func testNeverEvictsProtectedSongsEvenIfOldest() {
        let entries = [
            entry("a", bytes: 40, lastAccess: 1),
            entry("b", bytes: 40, lastAccess: 2),
        ]
        let plan = TVPlaybackCachePlan.entriesToEvict(
            existing: entries,
            incomingBytes: 40,
            capacityBytes: 50,
            protectedSongIds: ["a"]
        )
        // "a" is oldest but protected (currently playing) — "b" must go instead.
        XCTAssertEqual(plan, ["b"])
    }

    func testEvictsMultipleEntriesUntilBudgetSatisfied() {
        let entries = [
            entry("a", bytes: 10, lastAccess: 1),
            entry("b", bytes: 10, lastAccess: 2),
            entry("c", bytes: 10, lastAccess: 3),
        ]
        let plan = TVPlaybackCachePlan.entriesToEvict(
            existing: entries,
            incomingBytes: 25,
            capacityBytes: 35,
            protectedSongIds: []
        )
        XCTAssertEqual(plan, ["a", "b"])
    }

    func testCannotFreeEnoughSpaceStillReturnsAllEvictableEntries() {
        let entries = [entry("a", bytes: 10, lastAccess: 1)]
        let plan = TVPlaybackCachePlan.entriesToEvict(
            existing: entries,
            incomingBytes: 1000,
            capacityBytes: 5,
            protectedSongIds: []
        )
        XCTAssertEqual(plan, ["a"])
    }
}
