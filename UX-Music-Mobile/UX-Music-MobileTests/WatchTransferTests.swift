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
}
