import XCTest
@testable import UX_Music_TV

/// Pure state-machine tests for the Phase 1-2 pairing flow — no networking involved.
final class TVPairingReducerTests: XCTestCase {
    func testSelectingHostMovesToStarting() {
        let next = TVPairingReducer.reduce(.idle, .selectedHost(displayName: "Mac mini"))
        XCTAssertEqual(next, .starting(hostDisplayName: "Mac mini"))
    }

    func testStartSucceededMovesToAwaitingConfirmationWithPayload() {
        let starting = TVPairingState.starting(hostDisplayName: "Mac mini")
        let start = TVPairingStart(sessionId: "s1", code: "123456", expiresAt: "2026-08-11T00:02:00Z")

        let next = TVPairingReducer.reduce(starting, .startSucceeded(start))

        XCTAssertEqual(next, .awaitingConfirmation(hostDisplayName: "Mac mini", start: start))
    }

    func testStartFailedMovesToFailed() {
        let starting = TVPairingState.starting(hostDisplayName: "Mac mini")
        let next = TVPairingReducer.reduce(starting, .startFailed("network error"))
        XCTAssertEqual(next, .failed(message: "network error"))
    }

    func testBeginConfirmingMovesFromAwaitingConfirmationToConfirming() {
        let start = TVPairingStart(sessionId: "s1", code: "123456", expiresAt: "")
        let awaiting = TVPairingState.awaitingConfirmation(hostDisplayName: "Mac mini", start: start)

        let next = TVPairingReducer.beginConfirming(awaiting)

        XCTAssertEqual(next, .confirming(hostDisplayName: "Mac mini", start: start))
    }

    func testConfirmSucceededMovesToPaired() {
        let start = TVPairingStart(sessionId: "s1", code: "123456", expiresAt: "")
        let confirming = TVPairingState.confirming(hostDisplayName: "Mac mini", start: start)

        let next = TVPairingReducer.reduce(confirming, .confirmSucceeded(deviceId: "device-1"))

        XCTAssertEqual(next, .paired(hostDisplayName: "Mac mini", deviceId: "device-1"))
    }

    func testConfirmFailedMovesToFailed() {
        let start = TVPairingStart(sessionId: "s1", code: "123456", expiresAt: "")
        let confirming = TVPairingState.confirming(hostDisplayName: "Mac mini", start: start)

        let next = TVPairingReducer.reduce(confirming, .confirmFailed("invalid pairing code"))

        XCTAssertEqual(next, .failed(message: "invalid pairing code"))
    }

    func testResetAlwaysReturnsToIdle() {
        let paired = TVPairingState.paired(hostDisplayName: "Mac mini", deviceId: "device-1")
        XCTAssertEqual(TVPairingReducer.reduce(paired, .reset), .idle)

        let failed = TVPairingState.failed(message: "x")
        XCTAssertEqual(TVPairingReducer.reduce(failed, .reset), .idle)
    }

    func testEventsThatDoNotMatchCurrentStateAreIgnored() {
        // startSucceeded while idle (no `starting` in flight) must not corrupt state.
        let start = TVPairingStart(sessionId: "s1", code: "123456", expiresAt: "")
        XCTAssertEqual(TVPairingReducer.reduce(.idle, .startSucceeded(start)), .idle)

        // confirmSucceeded while still awaitingConfirmation (confirm not yet issued) is ignored.
        let awaiting = TVPairingState.awaitingConfirmation(hostDisplayName: "Mac mini", start: start)
        XCTAssertEqual(TVPairingReducer.reduce(awaiting, .confirmSucceeded(deviceId: "d1")), awaiting)
    }
}
