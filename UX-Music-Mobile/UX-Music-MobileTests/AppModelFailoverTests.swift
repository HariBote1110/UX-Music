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
}
