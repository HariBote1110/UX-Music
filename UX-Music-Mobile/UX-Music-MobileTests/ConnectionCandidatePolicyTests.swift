import XCTest
@testable import UX_Music_Mobile

final class ConnectionCandidatePolicyTests: XCTestCase {
    func testHostsToTry_autoModeWhenPreferredHostNil() {
        let hosts = ConnectionCandidatePolicy.hostsToTry(
            primaryHost: "192.168.1.182",
            fallbackHosts: ["192.168.0.140", "100.116.252.72"],
            preferredHost: nil
        )
        XCTAssertEqual(hosts, ["192.168.1.182", "192.168.0.140", "100.116.252.72"])
    }

    func testHostsToTry_autoModeWhenPreferredHostEmpty() {
        let hosts = ConnectionCandidatePolicy.hostsToTry(
            primaryHost: "192.168.1.182",
            fallbackHosts: ["192.168.0.140"],
            preferredHost: "   "
        )
        XCTAssertEqual(hosts, ["192.168.1.182", "192.168.0.140"])
    }

    /// Fixed mode: only the preferred host is tried, even though it is not the current primary and
    /// there are other fallback hosts available — a stuck connection must surface as an error rather
    /// than silently failing over to a different NIC.
    func testHostsToTry_fixedModeReturnsOnlyPreferredHost() {
        let hosts = ConnectionCandidatePolicy.hostsToTry(
            primaryHost: "192.168.1.182",
            fallbackHosts: ["192.168.0.140", "100.116.252.72"],
            preferredHost: "100.116.252.72"
        )
        XCTAssertEqual(hosts, ["100.116.252.72"])
    }

    func testAllKnownHosts_combinesHostAndFallbackHostsDeduplicated() {
        var cfg = ServerConfig(host: "192.168.1.182", port: 8765)
        cfg.fallbackHosts = ["192.168.0.140", "192.168.1.182", "100.116.252.72"]
        XCTAssertEqual(cfg.allKnownHosts, ["192.168.1.182", "192.168.0.140", "100.116.252.72"])
    }

    func testIsTailscaleLikeHost_recognisesCGNATRange() {
        XCTAssertTrue(ServerConfig.isTailscaleLikeHost("100.116.252.72"))
        XCTAssertTrue(ServerConfig.isTailscaleLikeHost("100.64.0.1"))
        XCTAssertFalse(ServerConfig.isTailscaleLikeHost("192.168.1.182"))
        XCTAssertFalse(ServerConfig.isTailscaleLikeHost("100.128.0.1"))
        XCTAssertFalse(ServerConfig.isTailscaleLikeHost("not-an-ip"))
    }
}
