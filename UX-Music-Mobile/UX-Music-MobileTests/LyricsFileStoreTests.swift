import CryptoKit
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

@MainActor
final class LyricsFileStoreReplacementTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uxm-lyrics-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Mirrors `LyricsFileStore`'s private stem (SHA256 hex of the song id).
    private func stemFor(_ songId: String) -> String {
        SHA256.hash(data: Data(songId.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testFailedLrcWriteKeepsPreviousTxtLyrics() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LyricsFileStore(fileManager: .default, lyricsDirectoryOverride: dir)
        let sid = "song-replace-\(UUID().uuidString)"
        let stem = stemFor(sid)

        let oldTxt = dir.appendingPathComponent("\(stem).txt")
        try Data("old text".utf8).write(to: oldTxt)
        // A non-empty directory at the `.lrc` destination makes the atomic write fail.
        let blocker = dir.appendingPathComponent("\(stem).lrc", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("keep"))

        XCTAssertThrowsError(try store.saveLyrics("[00:01.00]New", wearType: "lrc", songId: sid))
        XCTAssertEqual(try String(contentsOf: oldTxt, encoding: .utf8), "old text")
    }

    func testSavingLrcReplacesOlderTxtAndLeavesOnlyLrc() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LyricsFileStore(fileManager: .default, lyricsDirectoryOverride: dir)
        let sid = "song-replace-\(UUID().uuidString)"
        let stem = stemFor(sid)

        let oldTxt = dir.appendingPathComponent("\(stem).txt")
        try Data("old text".utf8).write(to: oldTxt)
        try store.saveLyrics("[00:01.00]New", wearType: "lrc", songId: sid)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTxt.path))
        XCTAssertEqual(store.plainTextIfPresent(for: sid), "[00:01.00]New")
    }
}
