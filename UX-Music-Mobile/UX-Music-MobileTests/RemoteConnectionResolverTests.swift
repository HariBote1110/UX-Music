import XCTest
@testable import UX_Music_Mobile

final class RemoteConnectionResolverTests: XCTestCase {
    func testResolve_returnsFirstReachableCandidate() async {
        let candidates = [
            ServerConfig(host: "10.0.0.1", port: 8765),
            ServerConfig(host: "10.0.0.2", port: 8765),
        ]
        var pinged: [String] = []
        let result = await RemoteConnectionResolver.resolve(candidates: candidates) { config in
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
        _ = await RemoteConnectionResolver.resolve(candidates: candidates) { config in
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
        let result = await RemoteConnectionResolver.resolve(candidates: candidates) { _ in
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertNil(result)
    }

    func testResolve_returnsNilForEmptyCandidates() async {
        let result = await RemoteConnectionResolver.resolve(candidates: []) { _ in "desk" }
        XCTAssertNil(result)
    }

    /// Second sync bug: reachability (ping, unauthenticated) succeeding does not imply the token is
    /// valid — `checkAuthorised` must distinguish "reachable but 401" from "reachable and authorised".
    func testCheckAuthorised_returnsFalseOn401() async {
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: stubbedSession(statusCode: 401))
        let authorised = await RemoteConnectionResolver.checkAuthorised(client: client)
        XCTAssertFalse(authorised)
    }

    func testCheckAuthorised_returnsTrueOn200() async {
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: stubbedSession(statusCode: 200))
        let authorised = await RemoteConnectionResolver.checkAuthorised(client: client)
        XCTAssertTrue(authorised)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let res = HTTPURLResponse(url: request.url!, statusCode: StubURLProtocol.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: "{}".data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession(statusCode: Int) -> URLSession {
    StubURLProtocol.statusCode = statusCode
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}
