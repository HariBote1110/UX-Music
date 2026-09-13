import XCTest
@testable import UX_Music_Mobile

final class WatchHapticMapTests: XCTestCase {

    func testJSONRoundTripPreservesTheSharedContract() throws {
        let map = WatchHapticMap(
            version: WatchHapticMap.currentVersion,
            songId: "song-1",
            onsetTimes: [0.5, 1.0, 1.125],
            strengths: [0.8, 1.0, 0.35]
        )

        let data = try JSONEncoder().encode(map)
        XCTAssertEqual(try JSONDecoder().decode(WatchHapticMap.self, from: data), map)
    }

    func testHapticMetadataUsesTheSongIDAndKind() {
        let metadata = WatchTransferMeta.hapticsWcMetadata(songId: "song-1")

        XCTAssertEqual(metadata[WatchTransferMeta.metadataIDKey] as? String, "song-1")
        XCTAssertEqual(metadata[WatchTransferMeta.metadataKindKey] as? String, WatchTransferMeta.kindHaptics)
        XCTAssertTrue(WatchTransferMeta.isHapticsWcMetadata(metadata))
        XCTAssertFalse(WatchTransferMeta.isHapticsWcMetadata(nil))
        XCTAssertFalse(WatchTransferMeta.isHapticsWcMetadata([
            WatchTransferMeta.metadataIDKey: "song-1",
            WatchTransferMeta.metadataKindKey: WatchTransferMeta.kindArtwork
        ]))
    }

    func testMinimumOnsetGapMatchesTheDeviceResult() {
        XCTAssertEqual(WatchHapticMap.minimumOnsetGap, 0.125, accuracy: 0.000_000_001)
    }
}
