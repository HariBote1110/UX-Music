import XCTest
@testable import UX_Music_Mobile

/// Verifies the pure coverage function that decides how much black safe-area cover
/// should sit above the ambient background while the Now Playing side-panel strip
/// is dragged or settled on a side panel.  See NowPlayingView.swift for context.
final class NowPlayingCoverageTests: XCTestCase {
    func testMainAtRestIsZero() {
        let coverage = nowPlayingSidePanelCoverage(page: .main, horizontalDrag: 0, width: 390)
        XCTAssertEqual(coverage, 0, accuracy: 0.001)
    }

    func testQueueAtRestIsFull() {
        let coverage = nowPlayingSidePanelCoverage(page: .queue, horizontalDrag: 0, width: 390)
        XCTAssertEqual(coverage, 1, accuracy: 0.001)
    }

    func testFavouritesAtRestIsFull() {
        let coverage = nowPlayingSidePanelCoverage(page: .favourites, horizontalDrag: 0, width: 390)
        XCTAssertEqual(coverage, 1, accuracy: 0.001)
    }

    func testPlaybackSettingsIsAlwaysFull() {
        let coverage = nowPlayingSidePanelCoverage(page: .playbackSettings, horizontalDrag: 0, width: 390)
        XCTAssertEqual(coverage, 1, accuracy: 0.001)
    }

    func testMainMidDragIsAboutHalf() {
        let w: CGFloat = 390
        let coverage = nowPlayingSidePanelCoverage(page: .main, horizontalDrag: -w / 2, width: w)
        XCTAssertEqual(coverage, 0.5, accuracy: 0.02)
    }

    func testQueueRubberBandOverdragDoesNotExceedOne() {
        let w: CGFloat = 390
        // Dragging further to the right than the resting position over-shoots via rubber-banding.
        let coverage = nowPlayingSidePanelCoverage(page: .queue, horizontalDrag: 200, width: w)
        XCTAssertLessThanOrEqual(coverage, 1.0)
        XCTAssertGreaterThanOrEqual(coverage, 0.0)
    }

    func testZeroWidthIsZero() {
        let coverage = nowPlayingSidePanelCoverage(page: .queue, horizontalDrag: 0, width: 0)
        XCTAssertEqual(coverage, 0, accuracy: 0.001)
    }
}

/// Verifies the pure progress function driving the drag-to-reveal PlaybackSettings sheet
/// (the EQ panel that lifts from the bottom edge as the user drags upward on the main page).
final class NowPlayingSettingsSheetProgressTests: XCTestCase {
    func testNoDragIsZeroProgress() {
        let progress = nowPlayingSettingsSheetProgress(dragTranslationY: 0, height: 800)
        XCTAssertEqual(progress, 0, accuracy: 0.001)
    }

    func testDownwardDragDoesNotLiftSheet() {
        let progress = nowPlayingSettingsSheetProgress(dragTranslationY: 120, height: 800)
        XCTAssertEqual(progress, 0, accuracy: 0.001)
    }

    func testHalfHeightUpwardDragIsHalfProgress() {
        let progress = nowPlayingSettingsSheetProgress(dragTranslationY: -400, height: 800)
        XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    }

    func testOverdragClampsToOne() {
        let progress = nowPlayingSettingsSheetProgress(dragTranslationY: -2000, height: 800)
        XCTAssertEqual(progress, 1, accuracy: 0.001)
    }

    func testZeroHeightIsZeroProgress() {
        let progress = nowPlayingSettingsSheetProgress(dragTranslationY: -200, height: 0)
        XCTAssertEqual(progress, 0, accuracy: 0.001)
    }

    func testOffsetYAtZeroProgressIsFullHeight() {
        let offsetY = nowPlayingSettingsSheetOffsetY(progress: 0, height: 800)
        XCTAssertEqual(offsetY, 800, accuracy: 0.001)
    }

    func testOffsetYAtFullProgressIsZero() {
        let offsetY = nowPlayingSettingsSheetOffsetY(progress: 1, height: 800)
        XCTAssertEqual(offsetY, 0, accuracy: 0.001)
    }

    func testOffsetYIsClampedForOutOfRangeProgress() {
        XCTAssertEqual(nowPlayingSettingsSheetOffsetY(progress: -0.4, height: 800), 800, accuracy: 0.001)
        XCTAssertEqual(nowPlayingSettingsSheetOffsetY(progress: 1.4, height: 800), 0, accuracy: 0.001)
    }

    func testDarknessScalesWithProgressUpToHalfOpacity() {
        XCTAssertEqual(nowPlayingSettingsSheetDarkness(progress: 0), 0, accuracy: 0.001)
        XCTAssertEqual(nowPlayingSettingsSheetDarkness(progress: 0.5), 0.25, accuracy: 0.001)
        XCTAssertEqual(nowPlayingSettingsSheetDarkness(progress: 1), 0.5, accuracy: 0.001)
    }

    func testDarknessIsClampedForOutOfRangeProgress() {
        XCTAssertEqual(nowPlayingSettingsSheetDarkness(progress: -1), 0, accuracy: 0.001)
        XCTAssertEqual(nowPlayingSettingsSheetDarkness(progress: 2), 0.5, accuracy: 0.001)
    }

    func testShouldOpenBelowThresholdIsFalse() {
        XCTAssertFalse(nowPlayingSettingsSheetShouldOpen(progress: 0.1))
    }

    func testShouldOpenAboveThresholdIsTrue() {
        XCTAssertTrue(nowPlayingSettingsSheetShouldOpen(progress: 0.3))
    }

    // MARK: - Queue reorder destination translation
    //
    // `List.onMove`'s `destination` uses "gap index in the original array" semantics (matching
    // the classic `RangeReplaceableCollection.move(fromOffsets:toOffset:)` helper), whereas
    // `MusicPlayerService.moveQueueItem(from:to:)` expects the item's final resting index in the
    // *resulting* array. `nowPlayingQueueMoveDestination` bridges the two.

    func testMoveDestinationForwardSubtractsOneForTheRemovedSlot() {
        // [A,B,C,D], drag A (0) to the gap after C (destination 3) -> ends up at index 2: [B,C,A,D].
        XCTAssertEqual(nowPlayingQueueMoveDestination(from: 0, to: 3), 2)
    }

    func testMoveDestinationForwardToEndOfList() {
        // [A,B,C,D], drag A (0) to the gap past D (destination 4) -> ends up at index 3: [B,C,D,A].
        XCTAssertEqual(nowPlayingQueueMoveDestination(from: 0, to: 4), 3)
    }

    func testMoveDestinationBackwardIsUnchanged() {
        // [A,B,C,D], drag D (3) to the gap before A (destination 0) -> ends up at index 0: [D,A,B,C].
        XCTAssertEqual(nowPlayingQueueMoveDestination(from: 3, to: 0), 0)
    }

    func testMoveDestinationToSameSlotIsNoOp() {
        XCTAssertEqual(nowPlayingQueueMoveDestination(from: 2, to: 2), 2)
    }
}
