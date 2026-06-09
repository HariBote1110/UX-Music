import XCTest
@testable import UX_Music_Mobile

/// 十字スワイプ UI（Walkman Cross UI）の純ロジック仕様。
/// 状態遷移・スワイプ方向判定・連続キャンバスのレイアウト計算を固定する。
final class CrossPlayerNavigationTests: XCTestCase {
    // MARK: - Navigation state

    func testInitialPaneIsPlayer() {
        let state = MusicNavigationState()
        XCTAssertEqual(state.currentPane, .player)
        XCTAssertEqual(state.currentPane.title, "再生画面")
    }

    func testCrossDirectionsMoveToExpectedPanesFromPlayer() {
        var state = MusicNavigationState()

        state.move(.left)
        XCTAssertEqual(state.currentPane, .queue)

        state.move(.right)
        XCTAssertEqual(state.currentPane, .player)

        state.move(.right)
        XCTAssertEqual(state.currentPane, .favourites)

        state.move(.left)
        XCTAssertEqual(state.currentPane, .player)

        state.move(.up)
        XCTAssertEqual(state.currentPane, .library)

        state.move(.down)
        XCTAssertEqual(state.currentPane, .player)

        state.move(.down)
        XCTAssertEqual(state.currentPane, .settings)
    }

    func testOppositeDirectionReturnsToPlayerFromEachOuterPane() {
        let examples: [(MusicPane, MusicDirection)] = [
            (.queue, .right),
            (.favourites, .left),
            (.settings, .up),
            (.library, .down),
        ]

        for (pane, direction) in examples {
            var state = MusicNavigationState(currentPane: pane)
            state.move(direction)
            XCTAssertEqual(state.currentPane, .player)
        }
    }

    func testInvalidOuterPaneMovesStayInPlace() {
        var state = MusicNavigationState(currentPane: .queue)
        state.move(.left)
        state.move(.up)
        state.move(.down)
        XCTAssertEqual(state.currentPane, .queue)
    }

    func testPaneTitlesAndDescriptionsAreLocalised() {
        XCTAssertEqual(MusicPane.player.title, "再生画面")
        XCTAssertEqual(MusicPane.queue.title, "キュー")
        XCTAssertEqual(MusicPane.favourites.title, "お気に入り")
        XCTAssertEqual(MusicPane.library.title, "ライブラリ")
        XCTAssertEqual(MusicPane.settings.title, "設定")

        XCTAssertEqual(MusicPane.player.description, "Now Playing")
        XCTAssertEqual(MusicPane.queue.description, "再生キュー")
        XCTAssertEqual(MusicPane.favourites.description, "お気に入りの曲")
        XCTAssertEqual(MusicPane.settings.description, "EQ と設定")
        XCTAssertEqual(MusicPane.library.description, "プレイリストとアルバム")
    }

    // MARK: - Swipe resolver

    func testSwipeTranslationResolvesToDominantDirection() {
        XCTAssertEqual(MusicSwipeResolver.direction(forHorizontal: 86, vertical: 12), .left)
        XCTAssertEqual(MusicSwipeResolver.direction(forHorizontal: -94, vertical: -10), .right)
        XCTAssertEqual(MusicSwipeResolver.direction(forHorizontal: 8, vertical: 72), .up)
        XCTAssertEqual(MusicSwipeResolver.direction(forHorizontal: -6, vertical: -78), .down)
    }

    func testShortSwipeTranslationIsIgnored() {
        XCTAssertNil(MusicSwipeResolver.direction(forHorizontal: 28, vertical: 18))
    }

    func testDiagonalSwipeTranslationIsIgnored() {
        XCTAssertNil(MusicSwipeResolver.direction(forHorizontal: 90, vertical: 76))
        XCTAssertNil(MusicSwipeResolver.direction(forHorizontal: -84, vertical: -72))
        XCTAssertNil(MusicSwipeResolver.direction(forHorizontal: 78, vertical: -90))
    }

    func testDiagonalDragOffsetIsSuppressedWhileDragging() {
        let offset = MusicSwipeResolver.filteredDragOffset(horizontal: 90, vertical: 76)
        XCTAssertEqual(offset.x, 0)
        XCTAssertEqual(offset.y, 0)
    }

    func testDominantDragOffsetKeepsOnlyTheActiveAxis() {
        let horizontalOffset = MusicSwipeResolver.filteredDragOffset(horizontal: 120, vertical: 12)
        XCTAssertEqual(horizontalOffset.x, 120)
        XCTAssertEqual(horizontalOffset.y, 0)

        let verticalOffset = MusicSwipeResolver.filteredDragOffset(horizontal: 8, vertical: -130)
        XCTAssertEqual(verticalOffset.x, 0)
        XCTAssertEqual(verticalOffset.y, -130)
    }

    // MARK: - Layout

    func testCompactCrossLayoutFitsWithinSmallPhoneWidth() {
        XCTAssertLessThanOrEqual(CrossPlayerLayout.minimumRequiredWidth, 360)
    }

    func testFullScreenLayoutDoesNotReserveSpaceForDirectionButtons() {
        XCTAssertEqual(CrossPlayerLayout.directionButtonWidth, 0)
        XCTAssertGreaterThanOrEqual(CrossPlayerLayout.cardWidth(for: 368), 320)
    }

    func testMockUsesSwipeOnlyNavigationControls() {
        XCTAssertTrue(CrossPlayerLayout.usesSwipeOnlyNavigationControls)
    }

    func testPaneOriginsFormContinuousCrossAroundPlayer() {
        XCTAssertEqual(CrossPlayerLayout.origin(for: .player), PaneOrigin(x: 0, y: 0))
        XCTAssertEqual(CrossPlayerLayout.origin(for: .queue), PaneOrigin(x: -1, y: 0))
        XCTAssertEqual(CrossPlayerLayout.origin(for: .favourites), PaneOrigin(x: 1, y: 0))
        XCTAssertEqual(CrossPlayerLayout.origin(for: .library), PaneOrigin(x: 0, y: -1))
        XCTAssertEqual(CrossPlayerLayout.origin(for: .settings), PaneOrigin(x: 0, y: 1))
    }

    func testPaneOffsetTracksDragAsContinuousCanvas() {
        let offset = CrossPlayerLayout.offset(
            for: .queue,
            currentPane: .player,
            containerWidth: 360,
            containerHeight: 720,
            dragX: 80,
            dragY: 0
        )
        XCTAssertEqual(offset.x, -280)
        XCTAssertEqual(offset.y, 0)
    }

    func testInactivePanesArePlacedBeyondVisibleBounds() {
        let offset = CrossPlayerLayout.offset(
            for: .queue,
            currentPane: .player,
            containerWidth: 360,
            containerHeight: 720,
            dragX: 0,
            dragY: 0
        )
        XCTAssertLessThanOrEqual(offset.x, -720)
    }

    func testContentAvoidsStatusBarArea() {
        XCTAssertGreaterThanOrEqual(CrossPlayerLayout.topContentInset, 56)
    }

    func testPaneChromeDoesNotExposeOuterCardEdges() {
        XCTAssertEqual(CrossPlayerLayout.horizontalPadding, 0)
    }

    func testLibraryMenuUsesLargeStableTopAnchoredItems() {
        XCTAssertTrue(CrossPlayerLayout.libraryMenuUsesStableTopAnchoring)
        XCTAssertGreaterThanOrEqual(CrossPlayerLayout.libraryMenuItemMinHeight, 74)
        XCTAssertGreaterThanOrEqual(CrossPlayerLayout.libraryMenuIconSize, 26)
    }
}
