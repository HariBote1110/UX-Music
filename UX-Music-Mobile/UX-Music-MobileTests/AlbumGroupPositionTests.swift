import XCTest
@testable import UX_Music_Mobile

final class AlbumGroupPositionTests: XCTestCase {
    private func song(id: String, album: String) -> Song {
        Song(id: id, path: "/x/\(id)", title: id, album: album)
    }

    func testAllSingleSongGroupsAreSingle() {
        let songs = [song(id: "1", album: "A"), song(id: "2", album: "B"), song(id: "3", album: "C")]
        XCTAssertEqual(AlbumGrouping.positions(for: songs), [.single, .single, .single])
    }

    func testTwoSongGroupIsFirstThenLast() {
        let songs = [song(id: "1", album: "A"), song(id: "2", album: "A")]
        XCTAssertEqual(AlbumGrouping.positions(for: songs), [.first, .last])
    }

    func testThreeSongGroupHasMiddle() {
        let songs = [song(id: "1", album: "A"), song(id: "2", album: "A"), song(id: "3", album: "A")]
        XCTAssertEqual(AlbumGrouping.positions(for: songs), [.first, .middle, .last])
    }

    func testNonAdjacentRepeatsOfSameAlbumFormSeparateGroups() {
        let songs = [
            song(id: "1", album: "A"),
            song(id: "2", album: "B"),
            song(id: "3", album: "A"),
        ]
        XCTAssertEqual(AlbumGrouping.positions(for: songs), [.single, .single, .single])
    }

    func testMixOfGroupedAndUngrouped() {
        let songs = [
            song(id: "1", album: "A"),
            song(id: "2", album: "A"),
            song(id: "3", album: "B"),
        ]
        XCTAssertEqual(AlbumGrouping.positions(for: songs), [.first, .last, .single])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(AlbumGrouping.positions(for: []), [])
    }

    // MARK: - positions(forAlbumKeys:)
    //
    // The pure entry point `AlbumGrouping.positions(for:)` (above, keyed by the iOS-only `Song`
    // model) delegates to, so non-`Song` callers — namely the Watch's `WatchTransferMeta` via
    // `displayAlbum` — can share the same run-detection without depending on `Song`. See
    // `AlbumGroupPosition.swift`'s doc comment.

    func testPositionsForAlbumKeysDetectsRunsTheSameWayAsPositionsForSongs() {
        XCTAssertEqual(
            AlbumGrouping.positions(forAlbumKeys: ["A", "A", "B", "C", "C", "C"]),
            [.first, .last, .single, .first, .middle, .last]
        )
    }

    func testPositionsForAlbumKeysEmptyReturnsEmpty() {
        XCTAssertEqual(AlbumGrouping.positions(forAlbumKeys: []), [])
    }

    func testPositionsForSongsDelegatesToPositionsForAlbumKeys() {
        let songs = [
            song(id: "1", album: "A"),
            song(id: "2", album: "A"),
            song(id: "3", album: "B"),
        ]
        XCTAssertEqual(
            AlbumGrouping.positions(for: songs),
            AlbumGrouping.positions(forAlbumKeys: songs.map { $0.groupingAlbumTitle })
        )
    }
}

/// 連結線のジオメトリ。行を隙間なく積んだときに first→middle→last の線が
/// 途切れずつながることを保証する（以前は行ごとに 48pt の Canvas を描いていたため、
/// 行の上下パディング分だけ線が途切れて見えていた）。
final class AlbumGroupConnectorTests: XCTestCase {
    private let rowHeight: CGFloat = 64
    private let artworkSize: CGFloat = 48

    private func segment(_ position: AlbumGroupPosition) -> AlbumGroupConnector.Segment? {
        AlbumGroupConnector.verticalSegment(
            for: position,
            rowHeight: rowHeight,
            artworkSize: artworkSize
        )
    }

    func testSingleRowHasNoConnector() {
        XCTAssertNil(segment(.single))
        XCTAssertFalse(AlbumGroupConnector.hasElbow(for: .single))
    }

    /// 先頭行はアートワークを描くので、線はアートワーク下端から行の下端までのスタブ。
    func testFirstRowLineRunsFromArtworkBottomToRowBottom() {
        XCTAssertEqual(segment(.first)?.fromY, (rowHeight + artworkSize) / 2)
        XCTAssertEqual(segment(.first)?.toY, rowHeight)
        XCTAssertFalse(AlbumGroupConnector.hasElbow(for: .first))
    }

    func testMiddleRowLineSpansTheWholeRow() {
        XCTAssertEqual(segment(.middle)?.fromY, 0)
        XCTAssertEqual(segment(.middle)?.toY, rowHeight)
        XCTAssertFalse(AlbumGroupConnector.hasElbow(for: .middle))
    }

    /// 最終行は中央で止めて、そこから右へエルボーを描く（デスクトップの `└`）。
    func testLastRowLineStopsAtCentreAndDrawsElbow() {
        XCTAssertEqual(segment(.last)?.fromY, 0)
        XCTAssertEqual(segment(.last)?.toY, rowHeight / 2)
        XCTAssertTrue(AlbumGroupConnector.hasElbow(for: .last))
    }

    func testConnectorIsContinuousAcrossStackedRowsOfARun() {
        let positions: [AlbumGroupPosition] = [.first, .middle, .middle, .last]
        var lineEnd: CGFloat?
        for (index, position) in positions.enumerated() {
            let rowTop = CGFloat(index) * rowHeight
            guard let seg = segment(position) else {
                return XCTFail("\(index) 行目 (\(position)) に連結線がない")
            }
            if let previousEnd = lineEnd {
                XCTAssertEqual(
                    rowTop + seg.fromY,
                    previousEnd,
                    "\(index) 行目の線が前の行の終端とつながっていない"
                )
            }
            lineEnd = rowTop + seg.toY
        }
        // 最終行の中央で終わる
        XCTAssertEqual(lineEnd, 3 * rowHeight + rowHeight / 2)
    }
}
