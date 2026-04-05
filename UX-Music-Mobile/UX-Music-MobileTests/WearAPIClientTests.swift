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

    func testArtworkIdFromArtworkEndpointURL_decodesQuery() throws {
        let client = WearAPIClient(baseURLString: "http://192.168.0.2:8765")
        let u = try XCTUnwrap(URL(string: client.artworkURL(artworkId: "path/with/slash")))
        XCTAssertEqual(WearAPIClient.artworkId(fromArtworkEndpointURL: u), "path/with/slash")
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

    func testDecodeWearLyricsPayload() throws {
        let json = Data(#"{"found":true,"type":"lrc","content":"[00:01.00]Hi"}"#.utf8)
        let p = try JSONDecoder().decode(WearLyricsPayload.self, from: json)
        XCTAssertTrue(p.found)
        XCTAssertEqual(p.type, "lrc")
        XCTAssertEqual(p.content, "[00:01.00]Hi")
    }

    func testDecodeWearDesktopPlaylists() throws {
        let json = Data(
            #"[{"name":"Mix","songIds":["a","b"],"pathsNotInLibrary":["/gone.flac"]}]"#.utf8
        )
        let rows = try JSONDecoder().decode([WearDesktopPlaylist].self, from: json)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Mix")
        XCTAssertEqual(rows[0].songIds, ["a", "b"])
        XCTAssertEqual(rows[0].pathsNotInLibrary, ["/gone.flac"])
    }
}
