import XCTest
@testable import UX_Music_Mobile

final class SituationPlaylistResolverTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(id: id, path: "/x/\(id)", title: "T-\(id)")
    }

    func testResolvesSongIdsAgainstLibraryPreservingOrder() {
        let library = [song("a"), song("b"), song("c")]
        let playlists = [SituationPlaylist(name: "最近追加した曲", songIds: ["c", "a"])]
        let sections = SituationPlaylistResolver.resolve(playlists, library: library)
        XCTAssertEqual(sections.map(\.name), ["最近追加した曲"])
        XCTAssertEqual(sections[0].songs.map(\.id), ["c", "a"])
    }

    func testDropsSongIdsMissingFromLibrary() {
        let library = [song("a")]
        let playlists = [SituationPlaylist(name: "よく聴く曲", songIds: ["a", "missing"])]
        let sections = SituationPlaylistResolver.resolve(playlists, library: library)
        XCTAssertEqual(sections[0].songs.map(\.id), ["a"])
    }

    func testOmitsPlaylistsThatResolveToNoSongs() {
        let library = [song("a")]
        let playlists = [
            SituationPlaylist(name: "全部欠落", songIds: ["missing1", "missing2"]),
            SituationPlaylist(name: "残る", songIds: ["a"]),
        ]
        let sections = SituationPlaylistResolver.resolve(playlists, library: library)
        XCTAssertEqual(sections.map(\.name), ["残る"])
    }

    func testEmptyPlaylistsProduceEmptySections() {
        XCTAssertEqual(SituationPlaylistResolver.resolve([], library: [song("a")]), [])
    }

    func testPreservesPlaylistOrder() {
        let library = [song("a"), song("b")]
        let playlists = [
            SituationPlaylist(name: "One", songIds: ["a"]),
            SituationPlaylist(name: "Two", songIds: ["b"]),
        ]
        let sections = SituationPlaylistResolver.resolve(playlists, library: library)
        XCTAssertEqual(sections.map(\.name), ["One", "Two"])
    }
}
