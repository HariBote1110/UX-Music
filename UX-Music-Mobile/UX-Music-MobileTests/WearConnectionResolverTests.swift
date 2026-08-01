import XCTest
@testable import UX_Music_Mobile

final class WearConnectionResolverTests: XCTestCase {
    func testResolve_returnsFirstReachableCandidate() async {
        let candidates = [
            ServerConfig(host: "10.0.0.1", port: 8765),
            ServerConfig(host: "10.0.0.2", port: 8765),
        ]
        var pinged: [String] = []
        let result = await WearConnectionResolver.resolve(candidates: candidates) { config in
            pinged.append(config.host)
            if config.host == "10.0.0.1" {
                throw URLError(.cannotConnectToHost)
            }
            return "desk"
        }
        XCTAssertEqual(result?.config.host, "10.0.0.2")
        XCTAssertEqual(result?.serverName, "desk")
        // Only the first two candidates should have been pinged (no third candidate exists here, but
        // this also documents that resolution stops once a candidate succeeds).
        XCTAssertEqual(pinged, ["10.0.0.1", "10.0.0.2"])
    }

    func testResolve_stopsPingingAfterFirstSuccess() async {
        let candidates = [
            ServerConfig(host: "10.0.0.1", port: 8765),
            ServerConfig(host: "10.0.0.2", port: 8765),
            ServerConfig(host: "10.0.0.3", port: 8765),
        ]
        var pinged: [String] = []
        _ = await WearConnectionResolver.resolve(candidates: candidates) { config in
            pinged.append(config.host)
            if config.host == "10.0.0.1" { return "desk" }
            XCTFail("Should not ping candidates after a success")
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertEqual(pinged, ["10.0.0.1"])
    }

    func testResolve_returnsNilWhenAllCandidatesFail() async {
        let candidates = [
            ServerConfig(host: "10.0.0.1", port: 8765),
            ServerConfig(host: "10.0.0.2", port: 8765),
        ]
        let result = await WearConnectionResolver.resolve(candidates: candidates) { _ in
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertNil(result)
    }

    func testResolve_returnsNilForEmptyCandidates() async {
        let result = await WearConnectionResolver.resolve(candidates: []) { _ in "desk" }
        XCTAssertNil(result)
    }
}
