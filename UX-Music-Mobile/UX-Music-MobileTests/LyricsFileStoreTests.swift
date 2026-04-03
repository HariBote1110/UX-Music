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
}
