import SwiftUI
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

/// Control タブのポーリング条件（画面表示中・タブ選択中・前面）の真理値表。
final class RemoteControlPollingPolicyTests: XCTestCase {

    func testPollsOnlyWhenOnScreenSelectedAndActive() {
        XCTAssertTrue(RemoteControlPollingPolicy.shouldPoll(isOnScreen: true, isTabSelected: true, scenePhase: .active))
    }

    func testDoesNotPollWhenNotOnScreen() {
        XCTAssertFalse(RemoteControlPollingPolicy.shouldPoll(isOnScreen: false, isTabSelected: true, scenePhase: .active))
    }

    func testDoesNotPollWhenTabNotSelected() {
        XCTAssertFalse(RemoteControlPollingPolicy.shouldPoll(isOnScreen: true, isTabSelected: false, scenePhase: .active))
    }

    func testDoesNotPollWhenInactiveOrBackground() {
        XCTAssertFalse(RemoteControlPollingPolicy.shouldPoll(isOnScreen: true, isTabSelected: true, scenePhase: .inactive))
        XCTAssertFalse(RemoteControlPollingPolicy.shouldPoll(isOnScreen: true, isTabSelected: true, scenePhase: .background))
    }
}


/// Remote タブのシャッフル・ループ・キュー一覧（`/v1/remote/state` の `queue` ブロックと `/v1/remote/queue`）の解析。
final class RemoteQueueParsingTests: XCTestCase {

    func testStateWithQueueBlockDecodesShuffleLoopAndAvailability() {
        let state: [String: Any] = [
            "title": "Song A",
            "queue": ["available": true, "shuffled": true, "loopMode": "all", "index": 2, "count": 10] as [String: Any],
        ]
        let snapshot = RemoteControlStateSnapshot(from: state)
        XCTAssertTrue(snapshot.queueAvailable)
        XCTAssertTrue(snapshot.shuffled)
        XCTAssertEqual(snapshot.loopMode, .all)
        XCTAssertEqual(snapshot.queueIndex, 2)
        XCTAssertEqual(snapshot.queueCount, 10)
    }

    func testStateWithoutQueueKeyIsUnavailable() {
        let snapshot = RemoteControlStateSnapshot(from: ["title": "TV"])
        XCTAssertFalse(snapshot.queueAvailable)
        XCTAssertFalse(snapshot.shuffled)
        XCTAssertEqual(snapshot.loopMode, .off)
        XCTAssertEqual(snapshot.queueIndex, -1)
        XCTAssertEqual(snapshot.queueCount, 0)
    }

    func testQueueBlockWithAvailableFalseIsUnavailable() {
        let snapshot = RemoteControlStateSnapshot(from: ["queue": ["available": false] as [String: Any]])
        XCTAssertFalse(snapshot.queueAvailable)
    }

    func testUnknownLoopModeFallsBackToOff() {
        let snapshot = RemoteControlStateSnapshot(from: ["queue": ["available": true, "loopMode": "weird"] as [String: Any]])
        XCTAssertEqual(snapshot.loopMode, .off)
    }

    func testQueueChangesMakeSnapshotsDiffer() {
        let a = RemoteControlStateSnapshot(from: ["queue": ["available": true, "index": 1, "count": 5] as [String: Any]])
        let b = RemoteControlStateSnapshot(from: ["queue": ["available": true, "index": 2, "count": 5] as [String: Any]])
        XCTAssertNotEqual(a, b)
    }

    func testLoopModeCyclesOffAllOneOff() {
        XCTAssertEqual(RemoteLoopMode.off.next, .all)
        XCTAssertEqual(RemoteLoopMode.all.next, .one)
        XCTAssertEqual(RemoteLoopMode.one.next, .off)
    }

    func testQueueParsesItemsAndIndex() throws {
        let json = #"""
        {"available":true,"shuffled":true,"loopMode":"one","index":1,
         "items":[{"id":"a","type":"local","title":"A","artist":"X","album":"Al","artworkId":"art1"},
                  {"id":"b","type":"youtube","title":"B","artist":"Y","album":"","artworkId":""}]}
        """#
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let queue = RemoteQueue(from: object)
        XCTAssertTrue(queue.available)
        XCTAssertTrue(queue.shuffled)
        XCTAssertEqual(queue.loopMode, .one)
        XCTAssertEqual(queue.index, 1)
        XCTAssertEqual(queue.items.map(\.id), ["a", "b"])
        XCTAssertEqual(queue.items[0].title, "A")
        XCTAssertEqual(queue.items[0].artist, "X")
        XCTAssertEqual(queue.items[0].artworkId, "art1")
        XCTAssertEqual(queue.items[1].type, "youtube")
    }

    func testQueueMissingFieldsDecodeToUnavailableEmpty() {
        let queue = RemoteQueue(from: [:])
        XCTAssertFalse(queue.available)
        XCTAssertEqual(queue.index, -1)
        XCTAssertTrue(queue.items.isEmpty)
    }

    func testQueueSkipsItemsWithoutId() {
        let queue = RemoteQueue(from: ["available": true, "items": [["title": "no id"], ["id": "ok", "title": "T"]] as [[String: Any]]])
        XCTAssertEqual(queue.items.map(\.id), ["ok"])
    }
}
