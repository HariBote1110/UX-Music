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
}
