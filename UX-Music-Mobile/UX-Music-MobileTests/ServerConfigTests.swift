import XCTest
@testable import UX_Music_Mobile

final class ServerConfigTests: XCTestCase {
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

    /// The device auth token (issued by `POST /v1/pairing/redeem`) must round-trip through persistence.
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

    /// Equatable must ignore `token` too — a manually re-entered or re-paired token must not break
    /// the "selected peer" checkmark comparison.
    func testEquatableIgnoresToken() {
        var a = ServerConfig(host: "10.0.0.1", port: 8765)
        var b = ServerConfig(host: "10.0.0.1", port: 8765)
        a.token = "one"
        b.token = "two"
        XCTAssertEqual(a, b)
    }

    // MARK: - Pairing QR (uxmusic://pair?host=&port=&secret=)

    func testPairingRequestFromPairingURL_parsesHostPortAndSecret() throws {
        let u = try XCTUnwrap(URL(string: "uxmusic://pair?host=10.0.0.2&port=8765&secret=abc123"))
        let request = try XCTUnwrap(ServerConfig.pairingRequest(fromPairingURL: u))
        XCTAssertEqual(request.host, "10.0.0.2")
        XCTAssertEqual(request.port, 8765)
        XCTAssertEqual(request.secret, "abc123")
    }

    func testPairingRequestFromPairingURL_defaultPort() throws {
        let u = try XCTUnwrap(URL(string: "uxmusic://pair?host=10.0.0.2&secret=abc123"))
        let request = try XCTUnwrap(ServerConfig.pairingRequest(fromPairingURL: u))
        XCTAssertEqual(request.host, "10.0.0.2")
        XCTAssertEqual(request.port, AppConstants.defaultServerPort)
    }

    func testPairingRequestFromPairingURL_rejectsWrongHostComponent() {
        let u = URL(string: "uxmusic://other?host=1.1.1.1&port=8765&secret=abc123")!
        XCTAssertNil(ServerConfig.pairingRequest(fromPairingURL: u))
    }

    func testPairingRequestFromPairingURL_rejectsMissingSecret() {
        let u = URL(string: "uxmusic://pair?host=10.0.0.2&port=8765")!
        XCTAssertNil(ServerConfig.pairingRequest(fromPairingURL: u))
    }

    /// The desktop no longer emits bare-token QR/URLs — only `uxmusic://pair?...&secret=` — so an
    /// `http(s)://` pairing link must not parse.
    func testPairingRequestFromPairingURL_rejectsHTTPScheme() {
        let u = URL(string: "http://192.168.1.1:8765/v1/identity?secret=abc123")!
        XCTAssertNil(ServerConfig.pairingRequest(fromPairingURL: u))
    }

    // MARK: - Multi-NIC hosts= (uxmusic://pair?host=&hosts=&port=&secret=)

    /// A desktop with several LAN NICs (Wi-Fi/Ethernet/Tailscale) embeds every reachable address in
    /// `hosts=` so the phone can probe each candidate rather than only the (possibly unreachable)
    /// primary `host=`.
    func testPairingRequestFromPairingURL_parsesHostsList() throws {
        let u = try XCTUnwrap(URL(string: "uxmusic://pair?host=192.168.1.182&hosts=192.168.1.182,192.168.0.140,100.116.252.72&port=8765&secret=abc123"))
        let request = try XCTUnwrap(ServerConfig.pairingRequest(fromPairingURL: u))
        XCTAssertEqual(request.host, "192.168.1.182")
        XCTAssertEqual(request.hosts, ["192.168.1.182", "192.168.0.140", "100.116.252.72"])
    }

    /// Older desktop builds only emit `host=` — the candidate list must still contain that one host.
    func testPairingRequestFromPairingURL_missingHostsFallsBackToHostOnly() throws {
        let u = try XCTUnwrap(URL(string: "uxmusic://pair?host=10.0.0.2&port=8765&secret=abc123"))
        let request = try XCTUnwrap(ServerConfig.pairingRequest(fromPairingURL: u))
        XCTAssertEqual(request.hosts, ["10.0.0.2"])
    }
}
