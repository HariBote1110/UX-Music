import XCTest
@testable import UX_Music_Mobile

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, URLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
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

final class WearAPIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func sessionWithMock() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testPingParsesHostname() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.contains("wear/ping") ?? false)
            let data = #"{"hostname":"desk"}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let client = WearAPIClient(baseURLString: "http://127.0.0.1:8765", session: sessionWithMock())
        let host = try await client.ping()
        XCTAssertEqual(host, "desk")
    }

    func testArtworkURL() {
        let client = WearAPIClient(baseURLString: "http://h:1")
        XCTAssertEqual(client.artworkURL(artworkId: "x"), "http://h:1/wear/artwork/?id=x")
        XCTAssertEqual(client.artworkURL(artworkId: ""), "")
    }

    /// Mobile default: original library file via `source=original` (Wear API 2+).
    func testWearFileDownloadURLIncludesOriginalSource() throws {
        guard var c = URLComponents(string: "http://192.168.0.5:8765") else {
            XCTFail("components")
            return
        }
        c.path = "/wear/file"
        c.queryItems = [
            URLQueryItem(name: "id", value: "track-1"),
            URLQueryItem(name: "source", value: "original"),
        ]
        let u = try XCTUnwrap(c.url)
        XCTAssertTrue(u.absoluteString.contains("source=original"), u.absoluteString)
    }

    /// Regression: path-shaped song ids must use query `id=`, not extra URL path segments (slashes break routing and cache paths).
    func testWearFileDownloadURLUsesQueryParameter() throws {
        guard var c = URLComponents(string: "http://192.168.0.5:8765") else {
            XCTFail("components")
            return
        }
        c.path = "/wear/file"
        c.queryItems = [URLQueryItem(name: "id", value: "/Users/x/EmoCosine/track のコピー.m4a")]
        let u = try XCTUnwrap(c.url)
        XCTAssertEqual(u.path, "/wear/file")
        XCTAssertTrue(u.query?.contains("id=") == true)
    }
}
