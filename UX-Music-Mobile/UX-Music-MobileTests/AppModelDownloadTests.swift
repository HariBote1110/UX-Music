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

    /// Ensures library UI can subscribe to `AppModel` for download mutations (not only `downloadProgress`).
    func testRemoveDownloadedSongBumpsDownloadLibraryRevision() throws {
        let model = AppModel()
        let id = "unit-test-rev-\(UUID().uuidString)"
        let s = Song(id: id, path: "/p", title: "T", artist: "Ar", album: "Al", albumArtist: "AA", artworkId: "")
        let url = model.downloadManager.localFileURL(songId: id)
        try Data().write(to: url)
        model.downloadManager.register(s)
        let revisionBeforeRemove = model.downloadLibraryRevision
        model.removeDownloadedSong(songId: id)
        XCTAssertEqual(model.downloadLibraryRevision, revisionBeforeRemove + 1)
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

    func testSniffFlacHeader() {
        let d = Data("fLaC".utf8) + Data(repeating: 0, count: 20)
        XCTAssertEqual(DownloadedTrackFormatSniffer.sniff(d), "flac")
    }

    func testSniffMp3ID3() {
        let d = Data("ID3".utf8) + Data(repeating: 0, count: 20)
        XCTAssertEqual(DownloadedTrackFormatSniffer.sniff(d), "mp3")
    }

    func testSniffIsoBMFF() {
        var d = Data(repeating: 0, count: 4)
        d.append(Data("ftyp".utf8))
        d.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(DownloadedTrackFormatSniffer.sniff(d), "m4a")
    }

    func testPreferredExtensionFallsBackToLibraryPath() {
        let empty = Data()
        let ext = DownloadedTrackFormatSniffer.preferredExtension(
            header: empty,
            libraryPath: "/Music/Album/track.flac",
            fileType: ""
        )
        XCTAssertEqual(ext, "flac")
    }

    func testFinalizeDownloadRenamesByMagicBytes() throws {
        let dm = DownloadManager()
        let id = "unit-fin-\(UUID().uuidString)"
        let song = Song(
            id: id,
            path: "/lib/x.m4a",
            title: "T",
            artist: "A",
            album: "Al",
            albumArtist: "",
            artworkId: ""
        )
        let temp = dm.temporaryDownloadURL(songId: id)
        let body = Data("fLaC".utf8) + Data(repeating: 0, count: 40)
        try body.write(to: temp, options: .atomic)
        try dm.finalizeDownloadedPart(at: temp, song: song)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        let onDisk = dm.localPathString(songId: id)
        XCTAssertTrue(onDisk.hasSuffix(".flac"), onDisk)
        try? FileManager.default.removeItem(atPath: onDisk)
    }

    // MARK: - AAC variant (DownloadAudioQuality: .aac / .both)

    private func song(id: String) -> Song {
        Song(id: id, path: "/lib/\(id).m4a", title: "T", artist: "A", album: "Al", albumArtist: "", artworkId: "")
    }

    func testIsDownloadedTrueWithOnlyAACVariantPresent() throws {
        let dm = DownloadManager()
        let id = "unit-aac-\(UUID().uuidString)"
        let s = song(id: id)
        try Data("aac-bytes".utf8).write(to: dm.aacVariantDestinationURL(songId: id))
        dm.register(s)
        XCTAssertTrue(dm.isDownloaded(songId: id))
        dm.remove(songId: id)
    }

    func testWatchTransferSourceURLPrefersAACVariantWhenPresent() throws {
        let dm = DownloadManager()
        let id = "unit-aac-\(UUID().uuidString)"
        let s = song(id: id)
        try Data("orig".utf8).write(to: dm.localFileURL(songId: id))
        dm.register(s)
        try Data("aac-bytes".utf8).write(to: dm.aacVariantDestinationURL(songId: id))
        let source = dm.watchTransferSourceURL(songId: id)
        XCTAssertEqual(source, dm.aacVariantDestinationURL(songId: id))
        dm.remove(songId: id)
    }

    func testWatchTransferSourceURLFallsBackToOriginalWhenNoAACVariant() throws {
        let dm = DownloadManager()
        let id = "unit-aac-\(UUID().uuidString)"
        let s = song(id: id)
        try Data("orig".utf8).write(to: dm.localFileURL(songId: id))
        dm.register(s)
        let source = dm.watchTransferSourceURL(songId: id)
        XCTAssertEqual(source?.lastPathComponent, dm.localFileURL(songId: id).lastPathComponent)
        dm.remove(songId: id)
    }

    func testWatchTransferSourceURLNilWhenNothingDownloaded() {
        let dm = DownloadManager()
        let id = "unit-aac-\(UUID().uuidString)"
        XCTAssertNil(dm.watchTransferSourceURL(songId: id))
    }

    func testLocalPathStringPrefersOriginalOverAACVariant() throws {
        let dm = DownloadManager()
        let id = "unit-aac-\(UUID().uuidString)"
        let s = song(id: id)
        try Data("orig".utf8).write(to: dm.localFileURL(songId: id))
        try Data("aac-bytes".utf8).write(to: dm.aacVariantDestinationURL(songId: id))
        dm.register(s)
        XCTAssertEqual(dm.localPathString(songId: id), dm.localFileURL(songId: id).path)
        dm.remove(songId: id)
    }

    func testLocalPathStringFallsBackToAACVariantWhenNoOriginal() throws {
        let dm = DownloadManager()
        let id = "unit-aac-\(UUID().uuidString)"
        let s = song(id: id)
        try Data("aac-bytes".utf8).write(to: dm.aacVariantDestinationURL(songId: id))
        dm.register(s)
        XCTAssertEqual(dm.localPathString(songId: id), dm.aacVariantDestinationURL(songId: id).path)
        dm.remove(songId: id)
    }

    func testRemoveDeletesAACVariantToo() throws {
        let dm = DownloadManager()
        let id = "unit-aac-\(UUID().uuidString)"
        let s = song(id: id)
        try Data("aac-bytes".utf8).write(to: dm.aacVariantDestinationURL(songId: id))
        dm.register(s)
        dm.remove(songId: id)
        XCTAssertNil(dm.localAACVariantURLIfPresent(songId: id))
    }

    func testFinalizeDownloadedAACPartStoresM4aAsVariant() throws {
        let dm = DownloadManager()
        let id = "unit-aac-\(UUID().uuidString)"
        let s = song(id: id)
        let temp = dm.temporaryDownloadURL(songId: id)
        // Minimal ISO-BMFF ("....ftyp") header so DownloadedTrackFormatSniffer sniffs "m4a".
        var body = Data([0, 0, 0, 0x18])
        body.append(Data("ftyp".utf8))
        body.append(Data(repeating: 0, count: 40))
        try body.write(to: temp, options: .atomic)
        try dm.finalizeDownloadedAACPart(at: temp, song: s)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertNotNil(dm.localAACVariantURLIfPresent(songId: id))
        try? FileManager.default.removeItem(at: dm.aacVariantDestinationURL(songId: id))
    }

    func testFinalizeDownloadedAACPartFallsBackToOriginalWhenServerFellBackToOriginalBytes() throws {
        let dm = DownloadManager()
        let id = "unit-aac-\(UUID().uuidString)"
        let s = song(id: id)
        let temp = dm.temporaryDownloadURL(songId: id)
        let body = Data("fLaC".utf8) + Data(repeating: 0, count: 40)
        try body.write(to: temp, options: .atomic)
        try dm.finalizeDownloadedAACPart(at: temp, song: s)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertNil(dm.localAACVariantURLIfPresent(songId: id))
        dm.register(s)
        XCTAssertTrue(dm.localPathString(songId: id).hasSuffix(".flac"))
        dm.remove(songId: id)
    }

    func testFinalizeDownloadedAACPartDiscardsWhenOriginalAlreadyPresent() throws {
        let dm = DownloadManager()
        let id = "unit-aac-\(UUID().uuidString)"
        let s = song(id: id)
        try Data("orig".utf8).write(to: dm.localFileURL(songId: id))
        dm.register(s)

        let temp = dm.temporaryDownloadURL(songId: id)
        let body = Data("fLaC".utf8) + Data(repeating: 0, count: 40)
        try body.write(to: temp, options: .atomic)
        try dm.finalizeDownloadedAACPart(at: temp, song: s)

        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertNil(dm.localAACVariantURLIfPresent(songId: id))
        XCTAssertEqual(dm.localPathString(songId: id), dm.localFileURL(songId: id).path)
        dm.remove(songId: id)
    }
}
