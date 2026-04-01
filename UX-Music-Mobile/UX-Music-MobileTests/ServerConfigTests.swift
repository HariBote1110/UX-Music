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
}
