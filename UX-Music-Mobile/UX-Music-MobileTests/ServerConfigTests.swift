import XCTest
@testable import UX_Music_Mobile

final class ServerConfigTests: XCTestCase {
    func testFromPairingURL_customScheme() throws {
        let u = try XCTUnwrap(URL(string: "uxmusic://pair?host=10.0.0.2&port=8765"))
        let cfg = try XCTUnwrap(ServerConfig.fromPairingURL(u))
        XCTAssertEqual(cfg.host, "10.0.0.2")
        XCTAssertEqual(cfg.port, 8765)
    }

    func testFromPairingURL_customScheme_defaultPort() throws {
        let u = try XCTUnwrap(URL(string: "uxmusic://pair?host=10.0.0.2"))
        let cfg = try XCTUnwrap(ServerConfig.fromPairingURL(u))
        XCTAssertEqual(cfg.host, "10.0.0.2")
        XCTAssertEqual(cfg.port, AppConstants.defaultServerPort)
    }

    func testFromPairingURL_httpWithPort() throws {
        let u = try XCTUnwrap(URL(string: "http://192.168.1.1:8765/wear/ping"))
        let cfg = try XCTUnwrap(ServerConfig.fromPairingURL(u))
        XCTAssertEqual(cfg.host, "192.168.1.1")
        XCTAssertEqual(cfg.port, 8765)
    }

    func testFromPairingURL_httpNoExplicitPortUsesDefaultServerPort() throws {
        let u = try XCTUnwrap(URL(string: "http://192.168.1.1/"))
        let cfg = try XCTUnwrap(ServerConfig.fromPairingURL(u))
        XCTAssertEqual(cfg.host, "192.168.1.1")
        XCTAssertEqual(cfg.port, AppConstants.defaultServerPort)
    }

    func testFromPairingURL_rejectsWrongHost() throws {
        let u = try XCTUnwrap(URL(string: "uxmusic://other?host=1.1.1.1&port=8765"))
        XCTAssertNil(ServerConfig.fromPairingURL(u))
    }

    func testBaseURLStringUsesHostWhenSet() {
        let cfg = ServerConfig(host: "192.168.0.5", port: 8765)
        XCTAssertEqual(cfg.baseURLString, "http://192.168.0.5:8765")
    }

    func testBaseURLStringUsesLocalhostWhenHostEmpty() {
        let cfg = ServerConfig(host: "", port: 9000)
        XCTAssertEqual(cfg.baseURLString, "http://localhost:9000")
    }

    func testIsConfigured() {
        XCTAssertFalse(ServerConfig(host: "", port: 8765).isConfigured)
        XCTAssertTrue(ServerConfig(host: "10.0.0.1", port: 8765).isConfigured)
    }

    /// Regression: older persisted `ServerConfig` JSON has no `fallbackHosts` key. Decoding must not fail.
    func testDecodeLegacyJSONWithoutFallbackHostsSucceeds() throws {
        let json = Data(#"{"host":"10.0.0.1","port":8765}"#.utf8)
        let cfg = try JSONDecoder().decode(ServerConfig.self, from: json)
        XCTAssertEqual(cfg.host, "10.0.0.1")
        XCTAssertEqual(cfg.port, 8765)
        XCTAssertEqual(cfg.fallbackHosts, [])
    }

    func testFallbackHostsEncodeDecodeRoundTrip() throws {
        var cfg = ServerConfig(host: "10.0.0.1", port: 8765)
        cfg.fallbackHosts = ["10.0.0.2", "desk.local"]
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)
        XCTAssertEqual(decoded.fallbackHosts, ["10.0.0.2", "desk.local"])
    }

    /// Equatable must ignore `fallbackHosts` so the "selected peer" checkmark in Settings keeps working
    /// after a failover promotes a different host into `fallbackHosts`.
    func testEquatableIgnoresFallbackHosts() {
        var a = ServerConfig(host: "10.0.0.1", port: 8765)
        var b = ServerConfig(host: "10.0.0.1", port: 8765)
        a.fallbackHosts = ["10.0.0.2"]
        b.fallbackHosts = []
        XCTAssertEqual(a, b)
    }

    /// Root cause of second sync failure: `wearAuthMiddleware` on the desktop rejects every
    /// endpoint except `/wear/ping` and `/wear/mobile` without a token. `ServerConfig` must carry it.
    func testTokenEncodeDecodeRoundTrip() throws {
        var cfg = ServerConfig(host: "10.0.0.1", port: 8765)
        cfg.token = "secret-token"
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(ServerConfig.self, from: data)
        XCTAssertEqual(decoded.token, "secret-token")
    }

    /// Regression: older persisted JSON has no `token` key. Decoding must not fail and must default to "".
    func testDecodeLegacyJSONWithoutTokenSucceeds() throws {
        let json = Data(#"{"host":"10.0.0.1","port":8765}"#.utf8)
        let cfg = try JSONDecoder().decode(ServerConfig.self, from: json)
        XCTAssertEqual(cfg.token, "")
    }

    func testFromPairingURL_customScheme_readsToken() throws {
        let u = try XCTUnwrap(URL(string: "uxmusic://pair?host=10.0.0.2&port=8765&token=abc123"))
        let cfg = try XCTUnwrap(ServerConfig.fromPairingURL(u))
        XCTAssertEqual(cfg.token, "abc123")
    }

    func testFromPairingURL_httpScheme_readsToken() throws {
        let u = try XCTUnwrap(URL(string: "http://192.168.1.1:8765/wear/ping?token=abc123"))
        let cfg = try XCTUnwrap(ServerConfig.fromPairingURL(u))
        XCTAssertEqual(cfg.token, "abc123")
    }

    /// Equatable must ignore `token` too — a manually re-entered or re-paired token must not break
    /// the "selected peer" checkmark comparison.
    func testEquatableIgnoresToken() {
        var a = ServerConfig(host: "10.0.0.1", port: 8765)
        var b = ServerConfig(host: "10.0.0.1", port: 8765)
        a.token = "one"
        b.token = "two"
        XCTAssertEqual(a, b)
    }
}
