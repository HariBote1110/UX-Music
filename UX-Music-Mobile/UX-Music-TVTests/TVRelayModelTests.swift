import XCTest
@testable import UX_Music_TV

/// Pure-logic tests for the Phase 3-3 TV relay receiver (`markdown/appletv-servermode-plan.md`
/// §3-3). Covers parsing the additive `relay` block from `GET /v1/remote/state`, and the
/// availability rule (`remote.relay.v1` capability present AND `relay.active`) that decides
/// whether the browse UI shows the "PCで再生中のYouTube" shelf entry.
final class TVRelayModelTests: XCTestCase {
    func testParseReturnsInactiveWhenRelayKeyMissing() {
        let block = TVRelayStateBlock.parse(fromStateJSON: [:])
        XCTAssertEqual(block, .inactive)
    }

    func testParseReadsActiveTitleAndThumbnail() {
        let json: [String: Any] = [
            "relay": [
                "active": true,
                "title": "Some YouTube Video",
                "thumbnail": "https://i.ytimg.com/vi/abc/hq.jpg"
            ]
        ]
        let block = TVRelayStateBlock.parse(fromStateJSON: json)
        XCTAssertEqual(block, TVRelayStateBlock(
            active: true,
            title: "Some YouTube Video",
            thumbnail: "https://i.ytimg.com/vi/abc/hq.jpg"
        ))
    }

    func testParseDefaultsMissingSubfieldsToInactiveShape() {
        let json: [String: Any] = ["relay": [String: Any]()]
        let block = TVRelayStateBlock.parse(fromStateJSON: json)
        XCTAssertFalse(block.active)
        XCTAssertEqual(block.title, "")
        XCTAssertEqual(block.thumbnail, "")
    }

    func testCapabilityPresenceChecksExactIdentifier() {
        XCTAssertTrue(TVRelayCapability.isPresent(in: ["remote.relay.v1"]))
        XCTAssertTrue(TVRelayCapability.isPresent(in: ["sync.v1", "remote.relay.v1"]))
        XCTAssertFalse(TVRelayCapability.isPresent(in: []))
        XCTAssertFalse(TVRelayCapability.isPresent(in: ["sync.v1"]))
    }

    func testAvailabilityRequiresBothCapabilityAndActiveRelay() {
        let activeRelay = TVRelayStateBlock(active: true, title: "T", thumbnail: "")
        let inactiveRelay = TVRelayStateBlock.inactive

        // Older host: no capability at all, even if somehow active is true.
        XCTAssertFalse(TVRelayAvailability.isAvailable(capabilities: [], relay: activeRelay))

        // Capable host, nothing currently playing through the relay.
        XCTAssertFalse(TVRelayAvailability.isAvailable(capabilities: ["remote.relay.v1"], relay: inactiveRelay))

        // Capable host, actively relaying.
        XCTAssertTrue(TVRelayAvailability.isAvailable(capabilities: ["remote.relay.v1"], relay: activeRelay))
    }

    // MARK: - Transport state (relay banner play/pause reflection)

    func testIsPlayingReadsRootLevelPlayingKey() {
        XCTAssertTrue(TVRelayTransportState.isPlaying(fromStateJSON: ["playing": true]))
        XCTAssertFalse(TVRelayTransportState.isPlaying(fromStateJSON: ["playing": false]))
    }

    func testIsPlayingFallsBackToProvidedDefaultWhenKeyMissing() {
        XCTAssertTrue(TVRelayTransportState.isPlaying(fromStateJSON: [:], defaultingTo: true))
        XCTAssertFalse(TVRelayTransportState.isPlaying(fromStateJSON: [:], defaultingTo: false))
    }

    func testIsPlayingDefaultsToTrueWhenNoFallbackGiven() {
        XCTAssertTrue(TVRelayTransportState.isPlaying(fromStateJSON: [:]))
    }

    // MARK: - Position/duration (relay seek bar, Task B)

    func testPositionParsesRootLevelPositionAndDuration() {
        let block = TVRelayPositionState.parse(fromStateJSON: ["position": 12.5, "duration": 200.0])
        XCTAssertEqual(block.position, 12.5)
        XCTAssertEqual(block.duration, 200.0)
        XCTAssertTrue(block.isSeekable)
    }

    func testPositionIsNotSeekableWhenDurationMissing() {
        let block = TVRelayPositionState.parse(fromStateJSON: ["position": 12.5])
        XCTAssertFalse(block.isSeekable)
    }

    func testPositionIsNotSeekableWhenDurationIsZero() {
        let block = TVRelayPositionState.parse(fromStateJSON: ["position": 0.0, "duration": 0.0])
        XCTAssertFalse(block.isSeekable)
    }

    func testPositionIsNotSeekableWhenDurationIsNegative() {
        let block = TVRelayPositionState.parse(fromStateJSON: ["position": 0.0, "duration": -1.0])
        XCTAssertFalse(block.isSeekable)
    }

    func testPositionClampsFractionToUnitRange() {
        let midway = TVRelayPositionState.parse(fromStateJSON: ["position": 50.0, "duration": 200.0])
        XCTAssertEqual(midway.fraction, 0.25, accuracy: 0.0001)

        let overrun = TVRelayPositionState.parse(fromStateJSON: ["position": 999.0, "duration": 200.0])
        XCTAssertEqual(overrun.fraction, 1.0, accuracy: 0.0001)

        let notSeekable = TVRelayPositionState.parse(fromStateJSON: [:])
        XCTAssertEqual(notSeekable.fraction, 0.0, accuracy: 0.0001)
    }

    func testSeekTargetClampsWithinDurationAndAppliesDelta() {
        let block = TVRelayPositionState(position: 30, duration: 200)
        XCTAssertEqual(block.seekTarget(delta: 10), 40)
        XCTAssertEqual(block.seekTarget(delta: -50), 0) // clamps to 0, never negative
        XCTAssertEqual(block.seekTarget(delta: 1000), 200) // clamps to duration
    }
}
