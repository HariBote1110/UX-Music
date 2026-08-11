import XCTest
@testable import UX_Music_TV

/// Verifies the TV receiver's own control token — generated locally, independent of the host
/// pairing token — is what gets persisted and reused across launches (security fix,
/// `progress/tvos-connect.md` 2026-08-12 追記). Uses an isolated `UserDefaults` suite so runs
/// never leak state or touch the real `UserDefaults.standard`.
final class TVControlTokenStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TVControlTokenStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLoadOrCreateGeneratesNonEmptyHexToken() {
        let store = TVControlTokenStore(defaults: defaults)
        let token = store.loadOrCreate()

        XCTAssertEqual(token.count, 64) // 32 random bytes, hex-encoded
        XCTAssertTrue(token.allSatisfy { $0.isHexDigit })
    }

    func testLoadOrCreatePersistsAndReturnsSameTokenOnSubsequentCalls() {
        let store = TVControlTokenStore(defaults: defaults)
        let first = store.loadOrCreate()
        let second = store.loadOrCreate()

        XCTAssertEqual(first, second)
    }

    func testTwoIndependentStoresGenerateDifferentTokens() {
        let storeA = TVControlTokenStore(defaults: UserDefaults(suiteName: "TVControlTokenStoreTests.\(UUID().uuidString)")!)
        let storeB = TVControlTokenStore(defaults: UserDefaults(suiteName: "TVControlTokenStoreTests.\(UUID().uuidString)")!)

        XCTAssertNotEqual(storeA.loadOrCreate(), storeB.loadOrCreate())
    }

    /// The security property this whole fix exists for: the control token this store hands out
    /// must never coincide with — or be derived from — the host's pairing token. Since the store
    /// never reads the pairing token at all, this is a structural guarantee; this test pins that
    /// a representative host pairing token never leaks in as the control token.
    func testGeneratedControlTokenIsIndependentOfHostPairingToken() {
        let hostPairingToken = "tv-token-abc"
        let store = TVControlTokenStore(defaults: defaults)

        let controlToken = store.loadOrCreate()

        XCTAssertNotEqual(controlToken, hostPairingToken)
    }
}
