import XCTest
@testable import UX_Music_Mobile

final class WatchTransferTests: XCTestCase {

    private func sample(id: String = "abc123") -> WatchTransferMeta {
        WatchTransferMeta(id: id, title: "Song", artist: "Artist", album: "Album", duration: 123.4, fileType: "m4a")
    }

    // MARK: - wcMetadata / fromWCMetadata round trip

    func testWCMetadataRoundTrip() {
        let meta = sample()
        let decoded = WatchTransferMeta.fromWCMetadata(meta.wcMetadata)
        XCTAssertEqual(decoded, meta)
    }

    func testFromWCMetadataReturnsNilWhenKeyMissing() {
        var dict = sample().wcMetadata
        dict.removeValue(forKey: WatchTransferMeta.metadataDurationKey)
        XCTAssertNil(WatchTransferMeta.fromWCMetadata(dict))
    }

    func testFromWCMetadataReturnsNilForWrongType() {
        var dict = sample().wcMetadata
        dict[WatchTransferMeta.metadataDurationKey] = "not-a-number"
        XCTAssertNil(WatchTransferMeta.fromWCMetadata(dict))
    }

    func testFromWCMetadataReturnsNilForNilDictionary() {
        XCTAssertNil(WatchTransferMeta.fromWCMetadata(nil))
    }

    // MARK: - Codable

    func testJSONEncodeDecodeRoundTrip() throws {
        let meta = sample()
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(WatchTransferMeta.self, from: data)
        XCTAssertEqual(decoded, meta)
    }

    // MARK: - storedFileName / storageStem

    func testStoredFileNameSanitisesPathSeparators() {
        let meta = sample(id: "Artist/Album/Song.flac")
        XCTAssertFalse(meta.storedFileName.contains("/"))
        XCTAssertTrue(meta.storedFileName.hasSuffix(".m4a"))
    }

    func testStorageStemIsStableForSameID() {
        XCTAssertEqual(WatchTransferMeta.storageStem(for: "abc/def"), WatchTransferMeta.storageStem(for: "abc/def"))
    }

    func testStorageStemFallsBackForEmptyID() {
        XCTAssertEqual(WatchTransferMeta.storageStem(for: ""), "untitled")
    }

    // MARK: - Display helpers

    func testDisplayFieldsFallBackWhenEmpty() {
        let meta = WatchTransferMeta(id: "1", title: "", artist: "", album: "", duration: 65, fileType: "mp3")
        XCTAssertEqual(meta.displayTitle, "Unknown Title")
        XCTAssertEqual(meta.displayArtist, "Unknown Artist")
        XCTAssertEqual(meta.displayAlbum, "Unknown Album")
        XCTAssertEqual(meta.formattedDuration, "1:05")
    }

    // MARK: - WatchLibraryIndex.adding

    func testAddingAppendsNewEntry() {
        let result = WatchLibraryIndex.adding(sample(id: "1"), to: [])
        XCTAssertEqual(result.map(\.id), ["1"])
    }

    func testAddingIsNoOpForDuplicateID() {
        let existing = [sample(id: "1")]
        let result = WatchLibraryIndex.adding(sample(id: "1"), to: existing)
        XCTAssertEqual(result.count, 1)
    }

    func testAddingPreservesOrder() {
        let existing = [sample(id: "1"), sample(id: "2")]
        let result = WatchLibraryIndex.adding(sample(id: "3"), to: existing)
        XCTAssertEqual(result.map(\.id), ["1", "2", "3"])
    }

    // MARK: - WatchLibraryIndex.removing

    func testRemovingDeletesMatchingID() {
        let existing = [sample(id: "1"), sample(id: "2")]
        let result = WatchLibraryIndex.removing(id: "1", from: existing)
        XCTAssertEqual(result.map(\.id), ["2"])
    }

    func testRemovingIsNoOpWhenIDNotPresent() {
        let existing = [sample(id: "1")]
        let result = WatchLibraryIndex.removing(id: "missing", from: existing)
        XCTAssertEqual(result.map(\.id), ["1"])
    }

    // MARK: - WatchLibraryIndex.retainingExistingFiles

    func testRetainingExistingFilesFiltersMissingFiles() {
        let existing = [sample(id: "1"), sample(id: "2")]
        let result = WatchLibraryIndex.retainingExistingFiles(existing) { $0.id == "1" }
        XCTAssertEqual(result.map(\.id), ["1"])
    }

    // MARK: - WatchFileReceiveHandling

    func testShouldAddToLibraryIsTrueOnSuccess() {
        XCTAssertTrue(WatchFileReceiveHandling.shouldAddToLibrary(.succeeded(sample())))
    }

    func testShouldAddToLibraryIsFalseOnFailure() {
        XCTAssertFalse(WatchFileReceiveHandling.shouldAddToLibrary(.failed("copy failed")))
    }

    // MARK: - WatchTransferActivationGating
    //
    // Pure gating logic for the "activate before transferFile" bug: on a real device,
    // WCSession.activate() completes asynchronously, so a `send` requested before
    // `activationDidCompleteWith` fires must be queued rather than attempted immediately
    // (attempting it immediately is what produced the "WCSession has not been activated" /
    // "Application context data is nil" errors seen on-device).

    func testShouldSendImmediatelyIsFalseBeforeActivation() {
        XCTAssertFalse(WatchTransferActivationGating.shouldSendImmediately(status: .notActivated))
        XCTAssertFalse(WatchTransferActivationGating.shouldSendImmediately(status: .activating))
    }

    func testShouldSendImmediatelyIsTrueOnceActivated() {
        XCTAssertTrue(WatchTransferActivationGating.shouldSendImmediately(status: .activated))
    }

    func testShouldSendImmediatelyIsFalseWhenActivationFailed() {
        XCTAssertFalse(WatchTransferActivationGating.shouldSendImmediately(status: .failed("boom")))
    }

    func testStatusAfterActivationCompletionSucceededIsActivated() {
        XCTAssertEqual(
            WatchTransferActivationGating.statusAfterActivationCompletion(succeeded: true, errorDescription: nil),
            .activated
        )
    }

    func testStatusAfterActivationCompletionFailedCarriesErrorDescription() {
        XCTAssertEqual(
            WatchTransferActivationGating.statusAfterActivationCompletion(succeeded: false, errorDescription: "network gone"),
            .failed("network gone")
        )
    }

    func testStatusAfterActivationCompletionFailedFallsBackToDefaultMessageWhenNoError() {
        XCTAssertEqual(
            WatchTransferActivationGating.statusAfterActivationCompletion(succeeded: false, errorDescription: nil),
            .failed("Watch connectivity activation failed")
        )
    }

    // MARK: - Artwork transfer

    func testWCMetadataOmitsArtworkFileNameWhenNil() {
        XCTAssertNil(sample().wcMetadata[WatchTransferMeta.metadataArtworkFileNameKey])
    }

    func testWCMetadataRoundTripPreservesArtworkFileName() {
        var meta = sample()
        meta.artworkFileName = WatchTransferMeta.storedArtworkFileName(forId: meta.id)
        let decoded = WatchTransferMeta.fromWCMetadata(meta.wcMetadata)
        XCTAssertEqual(decoded, meta)
    }

    func testArtworkWcMetadataMarksKindArtwork() {
        XCTAssertTrue(WatchTransferMeta.isArtworkWcMetadata(sample().artworkWcMetadata))
    }

    func testIsArtworkWcMetadataIsFalseForAudioMetadata() {
        XCTAssertFalse(WatchTransferMeta.isArtworkWcMetadata(sample().wcMetadata))
    }

    func testIsArtworkWcMetadataIsFalseForNil() {
        XCTAssertFalse(WatchTransferMeta.isArtworkWcMetadata(nil))
    }

    func testStoredArtworkFileNameIsJPEGAndSanitised() {
        let name = WatchTransferMeta.storedArtworkFileName(forId: "Artist/Album/Song")
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".jpg"))
    }
}
