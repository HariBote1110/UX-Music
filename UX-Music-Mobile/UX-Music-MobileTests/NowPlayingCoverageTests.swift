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
