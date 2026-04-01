import XCTest
@testable import UX_Music_Mobile

@MainActor
final class AppModelDownloadTests: XCTestCase {
    func testAlbumHasTracksToDownload() throws {
        let model = AppModel()
        let id1 = "unit-test-dl-\(UUID().uuidString.prefix(8))-1"
        let id2 = "unit-test-dl-\(UUID().uuidString.prefix(8))-2"
        let s1 = Song(id: id1, path: "/p", title: "A", artist: "Ar", album: "Al", albumArtist: "AA", artworkId: "")
        let s2 = Song(id: id2, path: "/p2", title: "B", artist: "Ar", album: "Al", albumArtist: "AA", artworkId: "")
        let album = Album(
            normalisedAlbumTitle: "Al",
            artistName: "AA",
            artworkId: "",
            songs: [s1, s2]
        )

        XCTAssertTrue(model.albumHasTracksToDownload(album))

        let url = model.downloadManager.localFileURL(songId: id1)
        try Data().write(to: url)
        model.downloadManager.register(s1)
        XCTAssertTrue(model.downloadManager.isDownloaded(songId: id1))

        XCTAssertTrue(model.albumHasTracksToDownload(album))

        let url2 = model.downloadManager.localFileURL(songId: id2)
        try Data().write(to: url2)
        model.downloadManager.register(s2)
        XCTAssertFalse(model.albumHasTracksToDownload(album))

        model.downloadManager.remove(songId: id1)
        model.downloadManager.remove(songId: id2)
    }

    func testPathLikeSongIdUsesFlatStoragePath() {
        let dm = DownloadManager()
        let pathLikeId = "/Users/me/EmoCosine/HYPER LOVE/002 のコピー.m4a"
        let url = dm.localFileURL(songId: pathLikeId)
        XCTAssertFalse(url.path.contains("HYPER LOVE"), url.path)
        XCTAssertTrue(url.path.contains("DownloadedTracks"))
        XCTAssertEqual(url.pathExtension, "m4a")
    }

    func testDownloadedArtworkLivesUnderDownloadedArtwork() {
        let dm = DownloadManager()
        let aid = "deadbeefcafe"
        let dest = dm.localArtworkDestinationURL(artworkId: aid)
        XCTAssertTrue(dest.path.contains("DownloadedArtwork"), dest.path)
        XCTAssertEqual(dest.pathExtension, "img")
        try! Data([0xFF, 0xD8, 0xFF]).write(to: dest)
        XCTAssertNotNil(dm.localArtworkFileURLIfPresent(artworkId: aid))
        try? FileManager.default.removeItem(at: dest)
    }
}
