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
}
