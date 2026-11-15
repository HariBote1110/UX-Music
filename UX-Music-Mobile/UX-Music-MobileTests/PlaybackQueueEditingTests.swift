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

    // MARK: - pinnedShuffleOrder
    //
    // Origins (index into the unshuffled queue) for each shuffled entry. Must follow exactly the
    // same reordering as `PlaybackShuffleLogic.applyShuffle`, which pins the current song first.

    func testPinnedShuffleOrderMovesCurrentSongToFront() {
        // shuffled ids [C,A,D,B]; current is B (origin 1) -> pinned to front.
        let order = PlaybackQueueEditing.pinnedShuffleOrder(
            queue: ["A", "B", "C", "D"], shuffledIndices: [2, 0, 3, 1], currentId: "B", id: { $0 }
        )
        XCTAssertEqual(order, [1, 2, 0, 3])
    }

    func testPinnedShuffleOrderKeepsOrderWhenCurrentMissing() {
        let order = PlaybackQueueEditing.pinnedShuffleOrder(
            queue: ["A", "B"], shuffledIndices: [1, 0], currentId: nil, id: { $0 }
        )
        XCTAssertEqual(order, [1, 0])
    }

    func testPinnedShuffleOrderMatchesApplyShuffleForSongs() {
        let songs = ["A", "B", "C", "D"].map { Song(id: $0, path: "/nonexistent/\($0).m4a", title: $0) }
        let indices = [2, 0, 3, 1]
        let order = PlaybackQueueEditing.pinnedShuffleOrder(
            queue: songs, shuffledIndices: indices, currentId: "B", id: { $0.id }
        )
        let applied = PlaybackShuffleLogic.applyShuffle(queue: songs, shuffledIndices: indices, currentId: "B")
        XCTAssertEqual(order.map { songs[$0] }, applied)
    }

    // MARK: - bookkeepingAfterRemoving (shuffle-on edits mirrored into the original order)

    func testRemovingWhileShuffledRemovesOriginEntryAndShiftsLaterOrigins() {
        // original [A,B,A,C]; shuffled [B,A,C,A] with origins [1,0,3,2]. Remove shuffled index 3 (origin 2).
        let state = PlaybackQueueEditing.ShuffleBookkeeping(originalQueue: ["A", "B", "A", "C"], origins: [1, 0, 3, 2])
        let result = PlaybackQueueEditing.bookkeepingAfterRemoving(
            queue: ["B", "A", "C", "A"], state: state, removedIndex: 3, id: { $0 }
        )
        XCTAssertEqual(result.originalQueue, ["A", "B", "C"])
        XCTAssertEqual(result.origins, [1, 0, 2])
    }

    func testRemovingFirstShuffledEntryKeepsOtherOriginsPointingAtTheirSongs() {
        // original [A,B,A,C]; shuffled [B,A,C,A] origins [1,0,3,2]. Remove shuffled index 0 (origin 1).
        let state = PlaybackQueueEditing.ShuffleBookkeeping(originalQueue: ["A", "B", "A", "C"], origins: [1, 0, 3, 2])
        let result = PlaybackQueueEditing.bookkeepingAfterRemoving(
            queue: ["B", "A", "C", "A"], state: state, removedIndex: 0, id: { $0 }
        )
        XCTAssertEqual(result.originalQueue, ["A", "A", "C"])
        XCTAssertEqual(result.origins, [0, 2, 1])
    }

    func testRemovingWhileOutOfStepFallsBackToIdLookup() {
        let state = PlaybackQueueEditing.ShuffleBookkeeping(originalQueue: ["A", "B"], origins: [])
        let result = PlaybackQueueEditing.bookkeepingAfterRemoving(
            queue: ["A", "B"], state: state, removedIndex: 1, id: { $0 }
        )
        XCTAssertEqual(result.originalQueue, ["A"])
        XCTAssertEqual(result.origins, [])
    }

    // MARK: - bookkeepingAfterAppending

    func testAppendingWhileShuffledAppendsOriginAtEnd() {
        let state = PlaybackQueueEditing.ShuffleBookkeeping(originalQueue: ["A", "B"], origins: [1, 0])
        let result = PlaybackQueueEditing.bookkeepingAfterAppending(queue: ["B", "A"], state: state, item: "Z")
        XCTAssertEqual(result.originalQueue, ["A", "B", "Z"])
        XCTAssertEqual(result.origins, [1, 0, 2])
    }

    func testAppendingToEmptyShuffledQueueGetsOriginZero() {
        let state = PlaybackQueueEditing.ShuffleBookkeeping<String>(originalQueue: [], origins: [])
        let result = PlaybackQueueEditing.bookkeepingAfterAppending(queue: [], state: state, item: "X")
        XCTAssertEqual(result.originalQueue, ["X"])
        XCTAssertEqual(result.origins, [0])
    }

    // MARK: - bookkeepingAfterInsertingNext

    func testInsertingNextWhileShuffledInsertsAfterCurrentOriginAndShiftsOrigins() {
        // original [A,B,C]; shuffled [C,A,B] origins [2,0,1]; current = A (shuffled index 1, origin 0).
        let state = PlaybackQueueEditing.ShuffleBookkeeping(originalQueue: ["A", "B", "C"], origins: [2, 0, 1])
        let result = PlaybackQueueEditing.bookkeepingAfterInsertingNext(
            queue: ["C", "A", "B"], state: state, currentIndex: 1, item: "X", id: { $0 }
        )
        XCTAssertEqual(result.originalQueue, ["A", "X", "B", "C"])
        XCTAssertEqual(result.origins, [3, 0, 1, 2])
    }

    func testInsertingNextWhileOutOfStepFallsBackToIdLookup() {
        let state = PlaybackQueueEditing.ShuffleBookkeeping(originalQueue: ["B", "A"], origins: [])
        let result = PlaybackQueueEditing.bookkeepingAfterInsertingNext(
            queue: ["A"], state: state, currentIndex: 0, item: "X", id: { $0 }
        )
        XCTAssertEqual(result.originalQueue, ["B", "A", "X"])
        XCTAssertEqual(result.origins, [])
    }

    // MARK: - bookkeepingAfterMoving

    func testMovingWhileShuffledReordersOriginsButNotOriginalQueue() {
        let state = PlaybackQueueEditing.ShuffleBookkeeping(originalQueue: ["A", "B", "C"], origins: [2, 0, 1])
        let result = PlaybackQueueEditing.bookkeepingAfterMoving(queue: ["C", "A", "B"], state: state, from: 0, to: 2)
        XCTAssertEqual(result.originalQueue, ["A", "B", "C"])
        XCTAssertEqual(result.origins, [0, 1, 2])
    }

    // MARK: - originalIndexOfCurrent / shuffledIndex

    func testOriginalIndexOfCurrentUsesExactOriginWithDuplicates() {
        // original [A,B,A]; shuffled [A(2),B(1),A(0)]. Current shuffled index 0 is the original second A.
        let state = PlaybackQueueEditing.ShuffleBookkeeping(originalQueue: ["A", "B", "A"], origins: [2, 1, 0])
        XCTAssertEqual(
            PlaybackQueueEditing.originalIndexOfCurrent(queue: ["A", "B", "A"], state: state, currentIndex: 0, currentId: "A", id: { $0 }),
            2
        )
    }

    func testOriginalIndexOfCurrentFallsBackToFirstOccurrenceWhenOutOfStep() {
        let state = PlaybackQueueEditing.ShuffleBookkeeping(originalQueue: ["A", "B", "A"], origins: [])
        XCTAssertEqual(
            PlaybackQueueEditing.originalIndexOfCurrent(queue: ["A", "B", "A"], state: state, currentIndex: 2, currentId: "A", id: { $0 }),
            0
        )
    }

    func testShuffledIndexOfOriginFindsPosition() {
        XCTAssertEqual(PlaybackQueueEditing.shuffledIndex(ofOriginal: 2, origins: [2, 1, 0]), 0)
        XCTAssertNil(PlaybackQueueEditing.shuffledIndex(ofOriginal: 5, origins: [2, 1, 0]))
    }
}
