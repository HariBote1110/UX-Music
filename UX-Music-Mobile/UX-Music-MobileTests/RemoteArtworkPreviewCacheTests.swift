import CryptoKit
import Foundation
import XCTest
@testable import UX_Music_Mobile

final class RemoteArtworkPreviewCacheTests: XCTestCase {
    func testStorageFileName_isStableHexDigest() {
        let name = RemoteArtworkPreviewCache.storageFileName(for: "my-artwork-key")
        let digest = SHA256.hash(data: Data("my-artwork-key".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(name, "\(hex).img")
    }

    func testStoreThenFileURLIfPresent_returnsFileURL() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteArtworkPreviewTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cache = RemoteArtworkPreviewCache(rootURL: tmp)
        let id = "artwork-test-id"
        let payload = Data("fake-jpeg-bytes".utf8)

        XCTAssertNil(cache.fileURLIfPresent(artworkId: id))

        try cache.store(data: payload, artworkId: id)
        let u = try XCTUnwrap(cache.fileURLIfPresent(artworkId: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.path))
        let roundtrip = try Data(contentsOf: u)
        XCTAssertEqual(roundtrip, payload)
    }

    func testFileURLIfPresent_emptyId_returnsNil() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = RemoteArtworkPreviewCache(rootURL: tmp)
        XCTAssertNil(cache.fileURLIfPresent(artworkId: ""))
    }
}
