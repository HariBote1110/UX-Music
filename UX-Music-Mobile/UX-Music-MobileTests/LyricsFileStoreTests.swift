import XCTest
@testable import UX_Music_Mobile

@MainActor
final class LyricsFileStoreTests: XCTestCase {
    func testSaveAndReadRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uxm-lyrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LyricsFileStore(fileManager: .default, lyricsDirectoryOverride: dir)
        let sid = "song-lyrics-\(UUID().uuidString)"
        try store.saveLyrics("[00:12.00]Line", wearType: "lrc", songId: sid)
        let text = store.plainTextIfPresent(for: sid)
        XCTAssertEqual(text?.trimmingCharacters(in: .whitespacesAndNewlines), "[00:12.00]Line")
        XCTAssertTrue(store.hasLyrics(for: sid))

        store.remove(for: sid)
        XCTAssertNil(store.plainTextIfPresent(for: sid))
        XCTAssertFalse(store.hasLyrics(for: sid))
    }

    func testSaveTranslationRoundTripsAndDoesNotDisturbMainLyrics() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uxm-lyrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LyricsFileStore(fileManager: .default, lyricsDirectoryOverride: dir)
        let sid = "song-lyrics-\(UUID().uuidString)"
        try store.saveLyrics("[00:12.00]Line", wearType: "lrc", songId: sid)
        try store.saveTranslation("[00:12.00]行", translationFormat: "lrc", songId: sid)

        XCTAssertEqual(store.plainTextIfPresent(for: sid)?.trimmingCharacters(in: .whitespacesAndNewlines), "[00:12.00]Line")
        XCTAssertEqual(store.translationPlainTextIfPresent(for: sid)?.trimmingCharacters(in: .whitespacesAndNewlines), "[00:12.00]行")
        XCTAssertTrue(store.hasLRCFile(for: sid))
        XCTAssertTrue(store.hasJaLRCFile(for: sid))
    }

    func testRemoveDeletesBothMainLyricsAndTranslation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uxm-lyrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LyricsFileStore(fileManager: .default, lyricsDirectoryOverride: dir)
        let sid = "song-lyrics-\(UUID().uuidString)"
        try store.saveLyrics("Line one", wearType: "txt", songId: sid)
        try store.saveTranslation("行一", translationFormat: "txt", songId: sid)

        store.remove(for: sid)

        XCTAssertNil(store.plainTextIfPresent(for: sid))
        XCTAssertNil(store.translationPlainTextIfPresent(for: sid))
        XCTAssertFalse(store.hasLyrics(for: sid))
    }

    func testResavingMainLyricsDoesNotDeleteTranslation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uxm-lyrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LyricsFileStore(fileManager: .default, lyricsDirectoryOverride: dir)
        let sid = "song-lyrics-\(UUID().uuidString)"
        try store.saveLyrics("Line one", wearType: "txt", songId: sid)
        try store.saveTranslation("行一", translationFormat: "txt", songId: sid)

        try store.saveLyrics("Updated line", wearType: "txt", songId: sid)

        XCTAssertEqual(store.translationPlainTextIfPresent(for: sid), "行一")
    }
}
