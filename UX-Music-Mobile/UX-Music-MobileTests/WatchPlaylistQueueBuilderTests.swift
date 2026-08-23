import XCTest
@testable import UX_Music_Mobile

final class WatchPlaylistQueueBuilderTests: XCTestCase {

    private func song(_ id: String) -> WatchTransferMeta {
        WatchTransferMeta(id: id, title: id, artist: "Artist", album: "Album", duration: 100, fileType: "m4a")
    }

    // MARK: - resolvedSongs

    func testResolvedSongsPreservesPlaylistOrder() {
        let playlist = WatchPlaylistMeta(id: "p1", name: "Mix", songIds: ["c", "a", "b"])
        let library = [song("a"), song("b"), song("c")]
        let resolved = WatchPlaylistQueueBuilder.resolvedSongs(for: playlist, librarySongs: library)
        XCTAssertEqual(resolved.map(\.id), ["c", "a", "b"])
    }

    func testResolvedSongsDropsMissingIds() {
        let playlist = WatchPlaylistMeta(id: "p1", name: "Mix", songIds: ["a", "missing", "b"])
        let library = [song("a"), song("b")]
        let resolved = WatchPlaylistQueueBuilder.resolvedSongs(for: playlist, librarySongs: library)
        XCTAssertEqual(resolved.map(\.id), ["a", "b"])
    }

    func testResolvedSongsIsEmptyWhenNoneMatch() {
        let playlist = WatchPlaylistMeta(id: "p1", name: "Mix", songIds: ["x", "y"])
        let resolved = WatchPlaylistQueueBuilder.resolvedSongs(for: playlist, librarySongs: [song("a")])
        XCTAssertTrue(resolved.isEmpty)
    }

    // MARK: - queue(for:startingAt:librarySongs:)

    func testQueueStartsAtRequestedSong() {
        let playlist = WatchPlaylistMeta(id: "p1", name: "Mix", songIds: ["a", "b", "c"])
        let library = [song("a"), song("b"), song("c")]
        let result = WatchPlaylistQueueBuilder.queue(for: playlist, startingAt: "b", librarySongs: library)
        XCTAssertEqual(result?.song.id, "b")
        XCTAssertEqual(result?.queue.map(\.id), ["a", "b", "c"])
    }

    func testQueueReturnsNilWhenStartSongNotResolved() {
        let playlist = WatchPlaylistMeta(id: "p1", name: "Mix", songIds: ["a", "b"])
        let library = [song("a"), song("b")]
        let result = WatchPlaylistQueueBuilder.queue(for: playlist, startingAt: "missing", librarySongs: library)
        XCTAssertNil(result)
    }

    func testQueueDropsMissingSongsButStillFindsStart() {
        let playlist = WatchPlaylistMeta(id: "p1", name: "Mix", songIds: ["a", "gone", "b"])
        let library = [song("a"), song("b")]
        let result = WatchPlaylistQueueBuilder.queue(for: playlist, startingAt: "b", librarySongs: library)
        XCTAssertEqual(result?.song.id, "b")
        XCTAssertEqual(result?.queue.map(\.id), ["a", "b"])
    }
}
