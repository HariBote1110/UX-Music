import XCTest
@testable import UX_Music_TV

final class TVRemoteCommandHandlerTests: XCTestCase {
    func testResolvesTransportActions() {
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "toggle", value: nil), .success(.toggle))
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "play", value: nil), .success(.play))
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "pause", value: nil), .success(.pause))
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "next", value: nil), .success(.next))
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "prev", value: nil), .success(.previous))
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "previous", value: nil), .success(.previous))
    }

    func testSeekRequiresValue() {
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "seek", value: 12.5), .success(.seek(12.5)))
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "seek", value: nil), .failure(.missingValue))
    }

    func testVolumeRequiresValue() {
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "volume", value: 0.5), .success(.volume(0.5)))
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "volume", value: nil), .failure(.missingValue))
    }

    func testUnsupportedActionIsReported() {
        XCTAssertEqual(TVRemoteCommandHandler.resolve(action: "shuffle", value: nil), .failure(.unsupportedAction("shuffle")))
    }

    func testStateBuilderShape() {
        let state = TVRemoteStateBuilder.state(
            title: "T", artist: "A", album: "Al", position: 10, duration: 200, playing: true, volume: 0.8
        )
        XCTAssertEqual(state["title"] as? String, "T")
        XCTAssertEqual(state["playing"] as? Bool, true)
        XCTAssertEqual(state["paused"] as? Bool, false)
        XCTAssertEqual(state["volume"] as? Double, 0.8)
    }

    func testAuthRequiresMatchingBearerToken() {
        XCTAssertTrue(TVRemoteAuth.isAuthorized(authorizationHeader: "Bearer abc123", expectedToken: "abc123"))
        XCTAssertFalse(TVRemoteAuth.isAuthorized(authorizationHeader: "Bearer wrong", expectedToken: "abc123"))
        XCTAssertFalse(TVRemoteAuth.isAuthorized(authorizationHeader: nil, expectedToken: "abc123"))
        XCTAssertFalse(TVRemoteAuth.isAuthorized(authorizationHeader: "Bearer abc123", expectedToken: ""))
        XCTAssertFalse(TVRemoteAuth.isAuthorized(authorizationHeader: "abc123", expectedToken: "abc123"))
    }

    /// Security fix (`progress/tvos-connect.md` 2026-08-12 追記): the receiver must authenticate
    /// against its own independently-generated control token, never the host pairing token — a
    /// caller presenting the host token (e.g. one leaked from a different channel) must be
    /// rejected once the receiver's `expectedToken` is the control token, not the host token.
    func testHostPairingTokenDoesNotAuthorizeAgainstIndependentControlToken() {
        let hostPairingToken = "host-pairing-token-xyz"
        let controlToken = "receiver-control-token-abc"
        XCTAssertNotEqual(hostPairingToken, controlToken)

        XCTAssertFalse(TVRemoteAuth.isAuthorized(
            authorizationHeader: "Bearer \(hostPairingToken)",
            expectedToken: controlToken
        ))
        XCTAssertTrue(TVRemoteAuth.isAuthorized(
            authorizationHeader: "Bearer \(controlToken)",
            expectedToken: controlToken
        ))
    }

    func testIdentityPayloadAlwaysReportsTVRole() {
        let payload = TVIdentityPayload.json(deviceName: "Living Room")
        XCTAssertEqual(payload["hostname"] as? String, "Living Room")
        XCTAssertEqual(payload["roles"] as? [String], ["tv"])
    }
}
