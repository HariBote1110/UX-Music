import XCTest
@testable import UX_Music_Mobile

/// Verifies `WatchPlaylistTransferEncoding`'s output round-trips through the exact `JSONDecoder`
/// call `WatchConnectivityReceiver.session(_:didReceive:)` uses on the Watch side
/// (`JSONDecoder().decode([WatchPlaylistMeta].self, from:)`), so a mismatch between the iOS sender
/// and the Watch decoder's expected field names would fail this test rather than only surfacing as
/// playlists silently failing to appear on a real device.
final class WatchPlaylistTransferEncodingTests: XCTestCase {

    private func playlist(id: String, name: String, songIds: [String]) -> Playlist {
        let now = Date()
        return Playlist(id: id, name: name, songIds: songIds, createdAt: now, updatedAt: now)
    }

    // MARK: - metas(for:)

    func testMetasMapsIdNameAndSongIds() {
        let playlists = [playlist(id: "p1", name: "Drive", songIds: ["s1", "s2"])]
        let metas = WatchPlaylistTransferEncoding.metas(for: playlists)
        XCTAssertEqual(metas, [WatchPlaylistMeta(id: "p1", name: "Drive", songIds: ["s1", "s2"])])
    }

    func testMetasPreservesPlaylistOrderAndSongOrder() {
        let playlists = [
            playlist(id: "p2", name: "Second", songIds: ["b", "a"]),
            playlist(id: "p1", name: "First", songIds: ["c"])
        ]
        let metas = WatchPlaylistTransferEncoding.metas(for: playlists)
        XCTAssertEqual(metas.map(\.id), ["p2", "p1"])
        XCTAssertEqual(metas.map(\.songIds), [["b", "a"], ["c"]])
    }

    // MARK: - jsonData(for:) round trip against the Watch decoder's expectations

    func testJSONDataRoundTripsThroughWatchDecoder() throws {
        let playlists = [
            playlist(id: "p1", name: "Drive", songIds: ["s1", "s2", "s3"]),
            playlist(id: "p2", name: "", songIds: [])
        ]
        let data = try XCTUnwrap(WatchPlaylistTransferEncoding.jsonData(for: playlists))
        let decoded = try JSONDecoder().decode([WatchPlaylistMeta].self, from: data)
        XCTAssertEqual(decoded, WatchPlaylistTransferEncoding.metas(for: playlists))
    }

    func testJSONDataForEmptyPlaylistsIsAnEmptyArray() throws {
        let data = try XCTUnwrap(WatchPlaylistTransferEncoding.jsonData(for: []))
        let decoded = try JSONDecoder().decode([WatchPlaylistMeta].self, from: data)
        XCTAssertTrue(decoded.isEmpty)
    }
}
