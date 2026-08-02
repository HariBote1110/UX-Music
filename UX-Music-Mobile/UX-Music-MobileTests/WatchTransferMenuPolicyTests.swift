import XCTest
@testable import UX_Music_Mobile

final class WatchTransferMenuPolicyTests: XCTestCase {

    // MARK: - canShowMenu

    func testCanShowMenuIsTrueWhenSupportedAndPaired() {
        XCTAssertTrue(WatchTransferMenuPolicy.canShowMenu(isWatchConnectivitySupported: true, isPaired: true))
    }

    func testCanShowMenuIsFalseWhenUnsupported() {
        XCTAssertFalse(WatchTransferMenuPolicy.canShowMenu(isWatchConnectivitySupported: false, isPaired: true))
    }

    func testCanShowMenuIsFalseWhenUnpaired() {
        XCTAssertFalse(WatchTransferMenuPolicy.canShowMenu(isWatchConnectivitySupported: true, isPaired: false))
    }

    // MARK: - songsEligibleForBulkTransfer

    private func song(id: String) -> Song {
        Song(
            id: id,
            path: "",
            title: "Title \(id)",
            artist: "Artist",
            album: "Album",
            duration: 120,
            fileType: "m4a",
            artworkId: ""
        )
    }

    func testSongsEligibleForBulkTransferKeepsOnlyDownloaded() {
        let songs = [song(id: "1"), song(id: "2"), song(id: "3")]
        let eligible = WatchTransferMenuPolicy.songsEligibleForBulkTransfer(songs, downloadedIds: ["1", "3"])
        XCTAssertEqual(eligible.map(\.id), ["1", "3"])
    }

    func testSongsEligibleForBulkTransferIsEmptyWhenNoneDownloaded() {
        let songs = [song(id: "1"), song(id: "2")]
        let eligible = WatchTransferMenuPolicy.songsEligibleForBulkTransfer(songs, downloadedIds: [])
        XCTAssertTrue(eligible.isEmpty)
    }

    func testSongsEligibleForBulkTransferPreservesOriginalOrder() {
        let songs = [song(id: "3"), song(id: "1"), song(id: "2")]
        let eligible = WatchTransferMenuPolicy.songsEligibleForBulkTransfer(songs, downloadedIds: ["1", "2", "3"])
        XCTAssertEqual(eligible.map(\.id), ["3", "1", "2"])
    }
}
