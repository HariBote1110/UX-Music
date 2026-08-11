import XCTest
@testable import UX_Music_TV

final class TVPlaylistQueueBuilderTests: XCTestCase {
    private func makeSong(id: String, title: String) -> Song {
        Song(
            id: id, path: "/tmp/\(id).flac", title: title, artist: "Artist", album: "Album",
            albumArtist: "Artist", year: 2024, genre: "", duration: 180, trackNumber: 1,
            discNumber: 1, fileSize: 0, fileType: "flac", sampleRate: nil, bitDepth: nil,
            artworkId: "", sourceType: .local, sourceURL: nil
        )
    }

    func testPreservesPlaylistOrderNotLibraryOrder() {
        let songs = [makeSong(id: "a", title: "A"), makeSong(id: "b", title: "B"), makeSong(id: "c", title: "C")]
        let playlist = RemoteDesktopPlaylist(name: "My List", songIds: ["c", "a"], pathsNotInLibrary: nil)

        let result = TVPlaylistQueueBuilder.songs(for: playlist, allSongs: songs)

        XCTAssertEqual(result.map(\.id), ["c", "a"])
    }

    func testSkipsIdsMissingFromLibrary() {
        let songs = [makeSong(id: "a", title: "A")]
        let playlist = RemoteDesktopPlaylist(name: "My List", songIds: ["missing", "a"], pathsNotInLibrary: ["/some/path.flac"])

        let result = TVPlaylistQueueBuilder.songs(for: playlist, allSongs: songs)

        XCTAssertEqual(result.map(\.id), ["a"])
    }

    func testEmptyWhenNoSongsLoaded() {
        let playlist = RemoteDesktopPlaylist(name: "My List", songIds: ["a"], pathsNotInLibrary: nil)

        XCTAssertTrue(TVPlaylistQueueBuilder.songs(for: playlist, allSongs: []).isEmpty)
    }

    func testEmptyWhenPlaylistHasNoSongIds() {
        let songs = [makeSong(id: "a", title: "A")]
        let playlist = RemoteDesktopPlaylist(name: "Empty", songIds: [], pathsNotInLibrary: nil)

        XCTAssertTrue(TVPlaylistQueueBuilder.songs(for: playlist, allSongs: songs).isEmpty)
    }
}
