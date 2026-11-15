import XCTest
@testable import UX_Music_Mobile

final class PlaybackQueueEditingTests: XCTestCase {

    // MARK: - moveElement

    func testMoveElementForwardShiftsOthersLeft() {
        let result = PlaybackQueueEditing.moveElement(in: ["A", "B", "C", "D"], from: 0, to: 3)
        XCTAssertEqual(result, ["B", "C", "D", "A"])
    }

    func testMoveElementBackwardShiftsOthersRight() {
        let result = PlaybackQueueEditing.moveElement(in: ["A", "B", "C", "D"], from: 3, to: 0)
        XCTAssertEqual(result, ["D", "A", "B", "C"])
    }

    func testMoveElementOutOfRangeFromIsNoOp() {
        let result = PlaybackQueueEditing.moveElement(in: ["A", "B"], from: 5, to: 0)
        XCTAssertEqual(result, ["A", "B"])
    }

    // MARK: - currentIndexAfterMoving

    func testCurrentIndexAfterMovingItselfLandsOnDestination() {
        XCTAssertEqual(PlaybackQueueEditing.currentIndexAfterMoving(from: 0, to: 3, currentIndex: 0), 3)
    }

    func testCurrentIndexAfterMovingSomeoneAcrossFromBeforeToAfterShiftsLeft() {
        // queue [A,B,C,D], current = C (index 2), move A(0) to 3
        XCTAssertEqual(PlaybackQueueEditing.currentIndexAfterMoving(from: 0, to: 3, currentIndex: 2), 1)
    }

    func testCurrentIndexAfterMovingSomeoneAcrossFromAfterToBeforeShiftsRight() {
        // queue [A,B,C,D], current = D (index 3), move A(0) to 1
        XCTAssertEqual(PlaybackQueueEditing.currentIndexAfterMoving(from: 0, to: 1, currentIndex: 3), 3)
    }

    func testCurrentIndexAfterMovingUnrelatedRangeIsUnchanged() {
        XCTAssertEqual(PlaybackQueueEditing.currentIndexAfterMoving(from: 3, to: 3, currentIndex: 1), 1)
    }

    // MARK: - currentIndexAfterRemoving

    func testRemovingBeforeCurrentShiftsIndexDown() {
        XCTAssertEqual(PlaybackQueueEditing.currentIndexAfterRemoving(removedIndex: 0, currentIndex: 2, countBefore: 4), 1)
    }

    func testRemovingAfterCurrentLeavesIndexUnchanged() {
        XCTAssertEqual(PlaybackQueueEditing.currentIndexAfterRemoving(removedIndex: 3, currentIndex: 1, countBefore: 4), 1)
    }

    func testRemovingCurrentAdvancesToWhatTakesItsPlace() {
        // [A,B,C,D], current=B(1); removing B leaves [A,C,D]; index 1 now points to C.
        XCTAssertEqual(PlaybackQueueEditing.currentIndexAfterRemoving(removedIndex: 1, currentIndex: 1, countBefore: 4), 1)
    }

    func testRemovingCurrentAtEndClampsToNewLastIndex() {
        // [A,B,C], current=C(2); removing C leaves [A,B]; clamp to last index 1.
        XCTAssertEqual(PlaybackQueueEditing.currentIndexAfterRemoving(removedIndex: 2, currentIndex: 2, countBefore: 3), 1)
    }

    func testRemovingLastRemainingItemReturnsNil() {
        XCTAssertNil(PlaybackQueueEditing.currentIndexAfterRemoving(removedIndex: 0, currentIndex: 0, countBefore: 1))
    }

    // MARK: - occurrenceIdentities
    //
    // Row identity for the Up Next list's `ForEach`. Keying purely on array offset means every
    // removal/reorder shifts the offsets (and hence ids) of all subsequent rows, so SwiftUI treats
    // them as brand-new rows and tears down/rebuilds instead of animating a clean move or delete —
    // this is the "old version remnants" ghosting. Occurrence-based ids (song id + how many earlier
    // entries share that id) stay stable across edits that don't touch the row's own song.

    func testOccurrenceIdentitiesAreUniqueForDuplicateSongs() {
        let ids = PlaybackQueueEditing.occurrenceIdentities(for: ["A", "A", "B"])
        XCTAssertEqual(ids, ["A#0", "A#1", "B#0"])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testOccurrenceIdentitiesAreStableWhenAnUnrelatedRowIsRemoved() {
        // Queue [A,B,C] -> remove B -> [A,C]. A and C keep their ids; only B's disappears.
        let before = PlaybackQueueEditing.occurrenceIdentities(for: ["A", "B", "C"])
        let after = PlaybackQueueEditing.occurrenceIdentities(for: ["A", "C"])
        XCTAssertEqual(before[0], after[0])
        XCTAssertEqual(before[2], after[1])
    }

    func testOccurrenceIdentitiesAreStableUnderReorderOfOtherRows() {
        // Queue [A,B,C,D] reordered to [B,C,D,A]: every row keeps its own id, just at a new offset.
        let before = PlaybackQueueEditing.occurrenceIdentities(for: ["A", "B", "C", "D"])
        let after = PlaybackQueueEditing.occurrenceIdentities(for: ["B", "C", "D", "A"])
        XCTAssertEqual(Set(before), Set(after))
    }

    func testOccurrenceIdentitiesSurvivorOfADuplicateKeepsAConsistentIdentityAfterTheOtherIsRemoved() {
        // Queue [A,A2,B] (both A copies share id "A") -> remove the first A -> [A2,B].
        // The surviving A now becomes occurrence 0, matching what the removed copy used to be.
        let before = PlaybackQueueEditing.occurrenceIdentities(for: ["A", "A", "B"])
        let after = PlaybackQueueEditing.occurrenceIdentities(for: ["A", "B"])
        XCTAssertEqual(before[1], "A#1")
        XCTAssertEqual(after[0], "A#0")
    }

    // MARK: - occurrenceRank / occurrenceIndex

    func testOccurrenceRankCountsEarlierItemsWithSameId() {
        let array = ["A", "B", "A", "C", "A"]
        XCTAssertEqual(PlaybackQueueEditing.occurrenceRank(ofIndex: 0, in: array, id: { $0 }), 0)
        XCTAssertEqual(PlaybackQueueEditing.occurrenceRank(ofIndex: 2, in: array, id: { $0 }), 1)
        XCTAssertEqual(PlaybackQueueEditing.occurrenceRank(ofIndex: 4, in: array, id: { $0 }), 2)
    }

    func testOccurrenceIndexPicksRankedOccurrenceAndFallsBackToFirst() {
        let array = ["A", "B", "A"]
        XCTAssertEqual(PlaybackQueueEditing.occurrenceIndex(rank: 1, ofId: "A", in: array, id: { $0 }), 2)
        // Rank 3 does not exist: fall back to the first occurrence.
        XCTAssertEqual(PlaybackQueueEditing.occurrenceIndex(rank: 3, ofId: "A", in: array, id: { $0 }), 0)
        XCTAssertNil(PlaybackQueueEditing.occurrenceIndex(rank: 0, ofId: "Z", in: array, id: { $0 }))
    }

    // MARK: - originalQueueAfterRemoving (shuffle-on edits mirrored into the unshuffled order)

    func testRemovingWhileShuffledRemovesSameSongFromOriginalOrder() {
        // Shuffled [B,A,C,A] over original [A,B,A,C]: removing the second A (rank 1) in the shuffled
        // queue removes the second A of the original order too.
        let queue = ["B", "A", "C", "A"]
        let original = ["A", "B", "A", "C"]
        let result = PlaybackQueueEditing.originalQueueAfterRemoving(
            queue: queue, originalQueue: original, removedIndex: 3, id: { $0 }
        )
        XCTAssertEqual(result, ["A", "B", "C"])
    }

    func testRemovingWhileShuffledFallsBackToFirstWhenRankMissingInOriginal() {
        // Duplicate was added while shuffled and only one copy exists in the original order.
        let queue = ["A", "B", "A"]
        let original = ["A", "B"]
        let result = PlaybackQueueEditing.originalQueueAfterRemoving(
            queue: queue, originalQueue: original, removedIndex: 2, id: { $0 }
        )
        XCTAssertEqual(result, ["B"])
    }

    func testRemovingWhileShuffledLeavesOriginalUnchangedWhenSongAbsent() {
        let result = PlaybackQueueEditing.originalQueueAfterRemoving(
            queue: ["A", "X"], originalQueue: ["A"], removedIndex: 1, id: { $0 }
        )
        XCTAssertEqual(result, ["A"])
    }

    // MARK: - originalQueueAfterAppending

    func testAppendingWhileShuffledAppendsToOriginalOrder() {
        XCTAssertEqual(
            PlaybackQueueEditing.originalQueueAfterAppending(originalQueue: ["A", "B"], appended: "Z"),
            ["A", "B", "Z"]
        )
    }

    // MARK: - originalQueueAfterInsertingNext

    func testInsertingNextWhileShuffledInsertsAfterCurrentInOriginalOrder() {
        // Shuffled [C,A,B] with current = A (index 1); original [A,B,C].
        let result = PlaybackQueueEditing.originalQueueAfterInsertingNext(
            queue: ["C", "A", "B"], originalQueue: ["A", "B", "C"], currentIndex: 1, inserted: "X", id: { $0 }
        )
        XCTAssertEqual(result, ["A", "X", "B", "C"])
    }

    func testInsertingNextWhileShuffledUsesRankOfCurrentDuplicate() {
        // Current is the second A (index 2, rank 1) of [A,B,A]; original [A,A,B] has its second A at 1.
        let result = PlaybackQueueEditing.originalQueueAfterInsertingNext(
            queue: ["A", "B", "A"], originalQueue: ["A", "A", "B"], currentIndex: 2, inserted: "X", id: { $0 }
        )
        XCTAssertEqual(result, ["A", "A", "X", "B"])
    }

    func testInsertingNextAppendsWhenCurrentCannotBeLocated() {
        let result = PlaybackQueueEditing.originalQueueAfterInsertingNext(
            queue: ["A"], originalQueue: ["B"], currentIndex: 0, inserted: "X", id: { $0 }
        )
        XCTAssertEqual(result, ["B", "X"])
    }
}
