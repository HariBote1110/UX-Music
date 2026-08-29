import XCTest
@testable import UX_Music_Mobile

/// `RemoteControlScreen.pollOnce()` used to write its whole `desktopState` dictionary
/// unconditionally every 2s tick, invalidating every view that reads it (title/artist/album/
/// transport button) even when the desktop reported the exact same track. This mirrors
/// `SidecarMetadataSnapshotTests` — `position` is deliberately excluded from the snapshot because
/// it must update every tick regardless of value (see `SidecarProgressInterpolation`).
final class RemoteControlStateSnapshotTests: XCTestCase {

    func testDecodesFieldsFromRawState() {
        let state: [String: Any] = [
            "title": "Song A",
            "artist": "Artist A",
            "album": "Album A",
            "duration": 180.5,
            "playing": true,
            "position": 12.3,
        ]
        let snapshot = RemoteControlStateSnapshot(from: state)
        XCTAssertEqual(snapshot.title, "Song A")
        XCTAssertEqual(snapshot.artist, "Artist A")
        XCTAssertEqual(snapshot.album, "Album A")
        XCTAssertEqual(snapshot.duration, 180.5)
        XCTAssertTrue(snapshot.playing)
    }

    func testMissingFieldsDecodeToDefaults() {
        let snapshot = RemoteControlStateSnapshot(from: [:])
        XCTAssertEqual(snapshot.title, "")
        XCTAssertEqual(snapshot.artist, "")
        XCTAssertEqual(snapshot.album, "")
        XCTAssertEqual(snapshot.duration, 0)
        XCTAssertFalse(snapshot.playing)
    }

    func testDurationAcceptsIntAndNSNumber() {
        XCTAssertEqual(RemoteControlStateSnapshot(from: ["duration": 200]).duration, 200)
        XCTAssertEqual(RemoteControlStateSnapshot(from: ["duration": NSNumber(value: 90.5)]).duration, 90.5)
    }

    func testEqualSnapshotsForIdenticalRawStateIgnoringPosition() {
        let a = RemoteControlStateSnapshot(from: ["title": "X", "artist": "Y", "playing": true, "position": 1.0])
        let b = RemoteControlStateSnapshot(from: ["title": "X", "artist": "Y", "playing": true, "position": 99.0])
        XCTAssertEqual(a, b, "position must not be part of the equatable snapshot")
    }

    func testUnequalWhenTitleDiffers() {
        let a = RemoteControlStateSnapshot(from: ["title": "X"])
        let b = RemoteControlStateSnapshot(from: ["title": "Z"])
        XCTAssertNotEqual(a, b)
    }

    func testUnequalWhenPlayingDiffers() {
        let a = RemoteControlStateSnapshot(from: ["playing": true])
        let b = RemoteControlStateSnapshot(from: ["playing": false])
        XCTAssertNotEqual(a, b)
    }

    func testEmptyIsTheDefaultAndEqualsDecodingAnEmptyDictionary() {
        XCTAssertEqual(RemoteControlStateSnapshot.empty, RemoteControlStateSnapshot(from: [:]))
    }
}
