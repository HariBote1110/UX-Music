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
}
