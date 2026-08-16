import XCTest
@testable import UX_Music_TV

/// Token persistence tests, using an isolated `UserDefaults` suite (never the real
/// `UserDefaults.standard`) so they can run repeatedly without leaking state.
final class TVServerConfigStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TVServerConfigStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLoadWithoutPriorSaveReturnsUnconfiguredDefault() {
        let store = TVServerConfigStore(defaults: defaults)
        let config = store.load()
        XCTAssertFalse(config.isConfigured)
        XCTAssertEqual(config.token, "")
    }

    func testSaveThenLoadRoundTripsHostPortAndToken() {
        let store = TVServerConfigStore(defaults: defaults)
        let config = ServerConfig(host: "192.168.1.10", port: 8765, token: "tv-token-abc")

        store.save(config)
        let loaded = store.load()

        XCTAssertEqual(loaded.host, "192.168.1.10")
        XCTAssertEqual(loaded.port, 8765)
        XCTAssertEqual(loaded.token, "tv-token-abc")
    }

    func testClearRemovesPersistedConfig() {
        let store = TVServerConfigStore(defaults: defaults)
        store.save(ServerConfig(host: "192.168.1.10", port: 8765, token: "tv-token-abc"))

        store.clear()

        XCTAssertFalse(store.load().isConfigured)
    }
}
