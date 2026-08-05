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
}
