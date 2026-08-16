import XCTest
@testable import UX_Music_Mobile

private final class FailoverMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, URLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = FailoverMockURLProtocol.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class AppModelFailoverTests: XCTestCase {
    override func tearDown() {
        FailoverMockURLProtocol.handler = nil
        super.tearDown()
    }

    private func sessionWithMock() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailoverMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Primary host is unreachable (`URLError`); the fallback host succeeds and is promoted to primary.
    func testWithFailover_promotesFallbackHostOnURLError() async throws {
        let model = AppModel()
        model.urlSession = sessionWithMock()
        model.serverConfig = ServerConfig(host: "primary.invalid", port: 8765)
        model.serverConfig.fallbackHosts = ["fallback.invalid"]

        FailoverMockURLProtocol.handler = { req in
            if req.url?.host == "primary.invalid" {
                throw URLError(.cannotConnectToHost)
            }
            let data = #"{"hostname":"desk"}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }

        let hostname = try await model.withFailover { client in try await client.ping() }

        XCTAssertEqual(hostname, "desk")
        XCTAssertEqual(model.serverConfig.host, "fallback.invalid")
        XCTAssertEqual(model.serverConfig.fallbackHosts, ["primary.invalid"])
    }

    /// An HTTP-status error means the server was reached — failover must not kick in.
    func testWithFailover_doesNotFailoverOnHTTPStatusError() async throws {
        let model = AppModel()
        model.urlSession = sessionWithMock()
        model.serverConfig = ServerConfig(host: "primary.invalid", port: 8765)
        model.serverConfig.fallbackHosts = ["fallback.invalid"]

        var attemptedHosts: [String] = []

        do {
            _ = try await model.withFailover { client in
                _ = client
                attemptedHosts.append("primary.invalid")
                throw RemoteAPIError.httpStatus(500)
            }
            XCTFail("Expected httpStatus error to propagate")
        } catch let error as RemoteAPIError {
            switch error {
            case .httpStatus(let code):
                XCTAssertEqual(code, 500)
            case .server:
                XCTFail("expected .httpStatus(500), got .server")
            }
        }

        XCTAssertEqual(attemptedHosts, ["primary.invalid"])
        XCTAssertEqual(model.serverConfig.host, "primary.invalid")
    }

    /// No fallback hosts configured and the primary fails: the error propagates.
    func testWithFailover_propagatesErrorWhenNoFallbackAvailable() async throws {
        let model = AppModel()
        model.urlSession = sessionWithMock()
        model.serverConfig = ServerConfig(host: "primary.invalid", port: 8765)

        FailoverMockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        do {
            _ = try await model.withFailover { client in try await client.ping() }
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        XCTAssertEqual(model.serverConfig.host, "primary.invalid")
    }

    // MARK: - Fixed connection mode (preferredHost)

    /// Fixed mode (`preferredHost` set): a failure on that host must propagate as an error rather
    /// than trying any `fallbackHosts` entry, even though some exist.
    func testWithFailover_fixedModeDoesNotTryFallbackHosts() async throws {
        let model = AppModel()
        model.urlSession = sessionWithMock()
        model.serverConfig = ServerConfig(host: "192.168.1.182", port: 8765)
        model.serverConfig.fallbackHosts = ["192.168.0.140"]
        model.serverConfig.preferredHost = "100.116.252.72"

        var attemptedHosts: [String] = []
        FailoverMockURLProtocol.handler = { req in
            attemptedHosts.append(req.url?.host ?? "")
            throw URLError(.cannotConnectToHost)
        }

        do {
            _ = try await model.withFailover { client in try await client.ping() }
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }

        XCTAssertEqual(attemptedHosts, ["100.116.252.72"])
        // Fixed mode must not rewrite `host`/`fallbackHosts` on failure.
        XCTAssertEqual(model.serverConfig.host, "192.168.1.182")
        XCTAssertEqual(model.serverConfig.fallbackHosts, ["192.168.0.140"])
    }

    /// Fixed mode succeeding must not promote the preferred host into `host` — there is nothing to
    /// fail over to, so `host`/`fallbackHosts` stay untouched.
    func testWithFailover_fixedModeSucceedsWithoutRewritingHost() async throws {
        let model = AppModel()
        model.urlSession = sessionWithMock()
        model.serverConfig = ServerConfig(host: "192.168.1.182", port: 8765)
        model.serverConfig.fallbackHosts = ["192.168.0.140"]
        model.serverConfig.preferredHost = "100.116.252.72"

        FailoverMockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.host, "100.116.252.72")
            let data = #"{"hostname":"desk"}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }

        let hostname = try await model.withFailover { client in try await client.ping() }

        XCTAssertEqual(hostname, "desk")
        XCTAssertEqual(model.serverConfig.host, "192.168.1.182")
        XCTAssertEqual(model.serverConfig.fallbackHosts, ["192.168.0.140"])
    }

    // MARK: - Multi-NIC QR pairing (uxmusic://pair?host=&hosts=&port=&secret=)

    /// The primary `host=` is unreachable but a `hosts=` candidate is: `applyPairingURL` must probe
    /// every candidate (like Discovery/`withFailover` do) rather than only trying the first one, and
    /// must save the reachable host as primary with the rest tucked into `fallbackHosts`.
    func testApplyPairingURL_probesHostsListAndSavesReachableHostAsPrimary() async throws {
        let model = AppModel()
        model.urlSession = sessionWithMock()

        FailoverMockURLProtocol.handler = { req in
            if req.url?.host == "192.168.1.182" {
                throw URLError(.cannotConnectToHost)
            }
            if req.url?.path == "/v1/pairing/redeem" {
                XCTAssertEqual(req.url?.host, "192.168.0.140")
                let data = #"{"deviceId":"dev1","token":"tok-123"}"#.data(using: .utf8)!
                let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, res)
            }
            let data = #"{"hostname":"desk"}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }

        let url = try XCTUnwrap(URL(string: "uxmusic://pair?host=192.168.1.182&hosts=192.168.1.182,192.168.0.140&port=8765&secret=abc123"))
        let ok = await model.applyPairingURL(url)

        XCTAssertTrue(ok)
        XCTAssertEqual(model.serverConfig.host, "192.168.0.140")
        XCTAssertEqual(model.serverConfig.token, "tok-123")
        XCTAssertEqual(model.serverConfig.fallbackHosts, ["192.168.1.182"])
        XCTAssertNil(model.pairingError)
    }

    /// None of the QR's candidate hosts are reachable: `pairingError` must tell the user to check
    /// their network rather than failing silently.
    func testApplyPairingURL_allHostsUnreachableSetsNetworkError() async throws {
        let model = AppModel()
        model.urlSession = sessionWithMock()

        FailoverMockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let url = try XCTUnwrap(URL(string: "uxmusic://pair?host=192.168.1.182&hosts=192.168.1.182,192.168.0.140&port=8765&secret=abc123"))
        let ok = await model.applyPairingURL(url)

        XCTAssertFalse(ok)
        XCTAssertEqual(model.pairingError, localizedString("Could not reach the desktop app. Check that you are on the same Wi-Fi network."))
    }

    /// A malformed or outdated QR (fails `ServerConfig.pairingRequest`) must not fail silently —
    /// `pairingError` must be set so the UI can surface it.
    func testApplyPairingURL_parseFailureSetsPairingError() async throws {
        let model = AppModel()
        model.urlSession = sessionWithMock()

        let url = try XCTUnwrap(URL(string: "uxmusic://pair?host=192.168.1.182"))
        let ok = await model.applyPairingURL(url)

        XCTAssertFalse(ok)
        XCTAssertEqual(model.pairingError, localizedString("Could not read the QR code. Please update the desktop app to the latest version."))
    }
}
