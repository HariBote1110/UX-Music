import XCTest
@testable import UX_Music_TV

final class TVPrefetchPlannerTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(id: id, path: "")
    }

    func testPrefetchesCurrentPlusNextTwoByDefault() {
        let queue = [song("a"), song("b"), song("c"), song("d")]
        let ids = TVPrefetchPlanner.songIdsToPrefetch(queue: queue, currentIndex: 0)
        XCTAssertEqual(ids, ["a", "b", "c"])
    }

    func testWrapsAtEndOfQueueWhenRepeatingIsIrrelevant_stopsAtQueueEnd() {
        let queue = [song("a"), song("b"), song("c")]
        let ids = TVPrefetchPlanner.songIdsToPrefetch(queue: queue, currentIndex: 2)
        XCTAssertEqual(ids, ["c"])
    }

    func testCustomPrefetchCount() {
        let queue = [song("a"), song("b"), song("c"), song("d"), song("e")]
        let ids = TVPrefetchPlanner.songIdsToPrefetch(queue: queue, currentIndex: 1, prefetchCount: 1)
        XCTAssertEqual(ids, ["b", "c"])
    }

    func testEmptyQueueYieldsNoIds() {
        XCTAssertEqual(TVPrefetchPlanner.songIdsToPrefetch(queue: [], currentIndex: 0), [])
    }

    func testOutOfRangeCurrentIndexYieldsNoIds() {
        let queue = [song("a")]
        XCTAssertEqual(TVPrefetchPlanner.songIdsToPrefetch(queue: queue, currentIndex: 5), [])
    }

    func testDeduplicatesWhenQueueHasFewerThanRequestedDistinctSongsRemaining() {
        let queue = [song("a"), song("b")]
        let ids = TVPrefetchPlanner.songIdsToPrefetch(queue: queue, currentIndex: 0, prefetchCount: 5)
        XCTAssertEqual(ids, ["a", "b"])
    }
}
