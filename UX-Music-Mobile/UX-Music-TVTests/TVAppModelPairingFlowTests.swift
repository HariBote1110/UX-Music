import XCTest
@testable import UX_Music_TV

/// End-to-end (but network-free) exercise of `TVAppModel.pair(with:)`, stubbing
/// `TVPairingClient` so the test never touches a real host — only pure logic and an isolated
/// `UserDefaults` suite are involved.
@MainActor
final class TVAppModelPairingFlowTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TVAppModelPairingFlowTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makePeer() -> LANDiscoveryPeer {
        LANDiscoveryPeer(
            name: "Mac mini",
            endpointHost: "macmini.local",
            addressHosts: ["192.168.1.10"],
            port: 8765,
            txt: ["displayName": "Mac mini"]
        )
    }

    func testSuccessfulPairingPersistsTokenAndReachesPairedState() async {
        let stub = StubTVPairingClient(
            startResult: .success(TVPairingStart(sessionId: "s1", code: "654321", expiresAt: "")),
            confirmResult: .success(TVPairingConfirmed(deviceId: "device-1", token: "tv-token"))
        )
        let model = TVAppModel(
            pairingClient: stub,
            store: TVServerConfigStore(defaults: defaults)
        )

        await model.pair(with: makePeer())

        XCTAssertEqual(model.pairingState, .paired(hostDisplayName: "Mac mini", deviceId: "device-1"))
        XCTAssertTrue(model.isPaired)
        XCTAssertEqual(model.serverConfig.token, "tv-token")
        XCTAssertEqual(TVServerConfigStore(defaults: defaults).load().token, "tv-token")
    }

    func testSuccessfulPairingAutoAdvancesToIdleAfterSuccessBeat() async {
        let stub = StubTVPairingClient(
            startResult: .success(TVPairingStart(sessionId: "s1", code: "654321", expiresAt: "")),
            confirmResult: .success(TVPairingConfirmed(deviceId: "device-1", token: "tv-token"))
        )
        let model = TVAppModel(
            pairingClient: stub,
            store: TVServerConfigStore(defaults: defaults),
            successAdvanceDelayNanoseconds: 0
        )

        await model.pair(with: makePeer())
        XCTAssertEqual(model.pairingState, .paired(hostDisplayName: "Mac mini", deviceId: "device-1"))

        // The auto-advance runs as its own zero-delay Task (see `scheduleAutoAdvanceFromPairedState`),
        // scheduled but not yet necessarily run the instant `pair(with:)` returns; give the run loop
        // a turn to execute it.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.pairingState, .idle)
        XCTAssertTrue(model.isPaired)
        XCTAssertEqual(model.serverConfig.token, "tv-token")
    }

    func testStartFailureLeavesNoTokenPersisted() async {
        let stub = StubTVPairingClient(
            startResult: .failure(TVPairingError.network("host unreachable")),
            confirmResult: .success(TVPairingConfirmed(deviceId: "device-1", token: "tv-token"))
        )
        let model = TVAppModel(
            pairingClient: stub,
            store: TVServerConfigStore(defaults: defaults)
        )

        await model.pair(with: makePeer())

        XCTAssertEqual(model.pairingState, .failed(message: "host unreachable"))
        XCTAssertFalse(model.isPaired)
        XCTAssertEqual(model.serverConfig.token, "")
    }

    func testConfirmFailureLeavesNoTokenPersisted() async {
        let stub = StubTVPairingClient(
            startResult: .success(TVPairingStart(sessionId: "s1", code: "654321", expiresAt: "")),
            confirmResult: .failure(TVPairingError.invalidResponse)
        )
        let model = TVAppModel(
            pairingClient: stub,
            store: TVServerConfigStore(defaults: defaults)
        )

        await model.pair(with: makePeer())

        XCTAssertEqual(model.pairingState, .failed(message: "サーバーからの応答が不正です。"))
        XCTAssertFalse(model.isPaired)
    }

    func testForgetPairingClearsPersistedTokenAndResetsState() async {
        let stub = StubTVPairingClient(
            startResult: .success(TVPairingStart(sessionId: "s1", code: "654321", expiresAt: "")),
            confirmResult: .success(TVPairingConfirmed(deviceId: "device-1", token: "tv-token"))
        )
        let model = TVAppModel(
            pairingClient: stub,
            store: TVServerConfigStore(defaults: defaults)
        )
        await model.pair(with: makePeer())
        XCTAssertTrue(model.isPaired)

        model.forgetPairing()

        XCTAssertFalse(model.isPaired)
        XCTAssertEqual(model.pairingState, .idle)
        XCTAssertFalse(TVServerConfigStore(defaults: defaults).load().isConfigured)
    }
}

private struct StubTVPairingClient: TVPairingClient {
    let startResult: Result<TVPairingStart, Error>
    let confirmResult: Result<TVPairingConfirmed, Error>

    func start(baseURL: String, deviceId: String, displayName: String) async throws -> TVPairingStart {
        try startResult.get()
    }

    func confirm(baseURL: String, sessionId: String, code: String) async throws -> TVPairingConfirmed {
        try confirmResult.get()
    }
}
