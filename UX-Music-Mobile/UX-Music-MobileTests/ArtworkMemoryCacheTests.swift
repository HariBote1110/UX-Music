import XCTest
@testable import UX_Music_Mobile

/// `ArtworkMemoryCache`'s capacity/eviction policy is the one part of the Watch artwork-decode
/// fix (see `WatchArtworkThumbnail` in `WatchSongListView.swift`) that is genuine pure logic, so it
/// is exercised here with a plain `String` payload rather than a real decoded `UIImage` — no image
/// decoding is needed to prove the LRU bookkeeping is correct.
final class ArtworkMemoryCacheTests: XCTestCase {
    func testStoresAndRetrievesAValue() {
        let cache = ArtworkMemoryCache<String>(capacity: 3)
        cache.setValue("jacket-1", forKey: "song-1")
        XCTAssertEqual(cache.value(forKey: "song-1"), "jacket-1")
    }

    func testMissingKeyReturnsNil() {
        let cache = ArtworkMemoryCache<String>(capacity: 3)
        XCTAssertNil(cache.value(forKey: "song-unknown"))
    }

    func testCountReflectsStoredEntries() {
        let cache = ArtworkMemoryCache<String>(capacity: 3)
        cache.setValue("a", forKey: "1")
        cache.setValue("b", forKey: "2")
        XCTAssertEqual(cache.count, 2)
    }

    func testOverwritingExistingKeyUpdatesValueWithoutGrowingCount() {
        let cache = ArtworkMemoryCache<String>(capacity: 3)
        cache.setValue("a", forKey: "1")
        cache.setValue("a-updated", forKey: "1")
        XCTAssertEqual(cache.value(forKey: "1"), "a-updated")
        XCTAssertEqual(cache.count, 1)
    }

    /// Once the cache is at capacity, inserting one more entry must evict exactly the
    /// least-recently-used one so a long library's worth of rows cannot grow it without bound.
    func testInsertingBeyondCapacityEvictsLeastRecentlyUsed() {
        let cache = ArtworkMemoryCache<String>(capacity: 2)
        cache.setValue("a", forKey: "1")
        cache.setValue("b", forKey: "2")
        cache.setValue("c", forKey: "3") // evicts "1", the least recently used

        XCTAssertNil(cache.value(forKey: "1"))
        XCTAssertEqual(cache.value(forKey: "2"), "b")
        XCTAssertEqual(cache.value(forKey: "3"), "c")
        XCTAssertEqual(cache.count, 2)
    }

    /// Reading a value must count as "using" it, so a row that is still on screen is not the one
    /// evicted just because it was inserted first.
    func testReadingAValueRefreshesItsRecency() {
        let cache = ArtworkMemoryCache<String>(capacity: 2)
        cache.setValue("a", forKey: "1")
        cache.setValue("b", forKey: "2")
        _ = cache.value(forKey: "1") // "1" is now more recently used than "2"
        cache.setValue("c", forKey: "3") // must evict "2", not "1"

        XCTAssertEqual(cache.value(forKey: "1"), "a")
        XCTAssertNil(cache.value(forKey: "2"))
        XCTAssertEqual(cache.value(forKey: "3"), "c")
    }

    func testRemoveValueDeletesTheEntry() {
        let cache = ArtworkMemoryCache<String>(capacity: 3)
        cache.setValue("a", forKey: "1")
        cache.removeValue(forKey: "1")
        XCTAssertNil(cache.value(forKey: "1"))
        XCTAssertEqual(cache.count, 0)
    }

    /// A capacity of 1 is the smallest useful cache and a good edge case for the eviction loop.
    func testCapacityOneKeepsOnlyTheMostRecentValue() {
        let cache = ArtworkMemoryCache<String>(capacity: 1)
        cache.setValue("a", forKey: "1")
        cache.setValue("b", forKey: "2")

        XCTAssertNil(cache.value(forKey: "1"))
        XCTAssertEqual(cache.value(forKey: "2"), "b")
        XCTAssertEqual(cache.count, 1)
    }
}
