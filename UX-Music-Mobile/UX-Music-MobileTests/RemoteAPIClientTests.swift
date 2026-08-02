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

final class RemoteAPIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func sessionWithMock() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testRemoteLANConfigurationBypassesSystemProxyAndCellularFallback() throws {
        let config = RemoteLANURLSession.makeConfiguration()
        let proxies = try XCTUnwrap(config.connectionProxyDictionary)

        XCTAssertEqual(proxies[RemoteLANProxyKeys.httpEnable] as? Int, 0)
        XCTAssertEqual(proxies[RemoteLANProxyKeys.httpsEnable] as? Int, 0)
        XCTAssertEqual(proxies[RemoteLANProxyKeys.socksEnable] as? Int, 0)
        XCTAssertEqual(proxies[RemoteLANProxyKeys.proxyAutoConfigEnable] as? Int, 0)
        XCTAssertFalse(config.allowsCellularAccess)
        XCTAssertFalse(config.allowsExpensiveNetworkAccess)
        XCTAssertFalse(config.waitsForConnectivity)
        XCTAssertNil(config.urlCache)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(config.timeoutIntervalForRequest, 10)
        XCTAssertEqual(config.timeoutIntervalForResource, 45)
    }

    func testPingParsesHostname() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.contains("v1/identity") ?? false)
            let data = #"{"hostname":"desk"}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: sessionWithMock())
        let host = try await client.ping()
        XCTAssertEqual(host, "desk")
    }

    func testArtworkURL() {
        let client = RemoteAPIClient(baseURLString: "http://h:1")
        XCTAssertEqual(client.artworkURL(artworkId: "x"), "http://h:1/v1/remote/artwork/?id=x")
        XCTAssertEqual(client.artworkURL(artworkId: ""), "")
    }

    func testArtworkIdFromArtworkEndpointURL_decodesQuery() throws {
        let client = RemoteAPIClient(baseURLString: "http://192.168.0.2:8765")
        let u = try XCTUnwrap(URL(string: client.artworkURL(artworkId: "path/with/slash")))
        XCTAssertEqual(RemoteAPIClient.artworkId(fromArtworkEndpointURL: u), "path/with/slash")
    }

    /// Mobile default: original library file via `source=original`.
    func testRemoteFileDownloadURLIncludesOriginalSource() throws {
        guard var c = URLComponents(string: "http://192.168.0.5:8765") else {
            XCTFail("components")
            return
        }
        c.path = "/v1/remote/file"
        c.queryItems = [
            URLQueryItem(name: "id", value: "track-1"),
            URLQueryItem(name: "source", value: "original"),
        ]
        let u = try XCTUnwrap(c.url)
        XCTAssertTrue(u.absoluteString.contains("source=original"), u.absoluteString)
    }

    /// Regression: path-shaped song ids must use query `id=`, not extra URL path segments (slashes break routing and cache paths).
    func testRemoteFileDownloadURLUsesQueryParameter() throws {
        guard var c = URLComponents(string: "http://192.168.0.5:8765") else {
            XCTFail("components")
            return
        }
        c.path = "/v1/remote/file"
        c.queryItems = [URLQueryItem(name: "id", value: "/Users/x/EmoCosine/track のコピー.m4a")]
        let u = try XCTUnwrap(c.url)
        XCTAssertEqual(u.path, "/v1/remote/file")
        XCTAssertTrue(u.query?.contains("id=") == true)
    }

    func testDecodeRemoteLyricsPayload() throws {
        let json = Data(#"{"found":true,"type":"lrc","content":"[00:01.00]Hi"}"#.utf8)
        let p = try JSONDecoder().decode(RemoteLyricsPayload.self, from: json)
        XCTAssertTrue(p.found)
        XCTAssertEqual(p.type, "lrc")
        XCTAssertEqual(p.content, "[00:01.00]Hi")
    }

    /// Every LAN API endpoint but `/v1/identity` and `/v1/pairing/*` requires
    /// `Authorization: Bearer <token>` (see progress/lan-api-v1.md).
    func testPingSendsBearerHeaderWhenTokenSet() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let data = #"{"hostname":"desk"}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", token: "secret", session: sessionWithMock())
        _ = try await client.ping()
    }

    func testFetchStateOmitsAuthorizationHeaderWhenTokenEmpty() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
            let data = "{}".data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: sessionWithMock())
        _ = try await client.fetchState()
    }

    func testFetchStateThrowsOnUnauthorized() async throws {
        MockURLProtocol.handler = { req in
            let data = #"{"error":{"code":"unauthorized","message":"Unauthorized"}}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: sessionWithMock())
        do {
            _ = try await client.fetchState()
            XCTFail("expected an error")
        } catch RemoteAPIError.server(let code, let message) {
            XCTAssertEqual(code, "unauthorized")
            XCTAssertEqual(message, "Unauthorized")
        }
    }

    func testArtworkURL_appendsTokenQueryWhenSet() {
        let client = RemoteAPIClient(baseURLString: "http://h:1", token: "abc def")
        XCTAssertEqual(client.artworkURL(artworkId: "x"), "http://h:1/v1/remote/artwork/?id=x&token=abc%20def")
    }

    func testDecodeRemoteDesktopPlaylists() throws {
        let json = Data(
            #"[{"name":"Mix","songIds":["a","b"],"pathsNotInLibrary":["/gone.flac"]}]"#.utf8
        )
        let rows = try JSONDecoder().decode([RemoteDesktopPlaylist].self, from: json)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "Mix")
        XCTAssertEqual(rows[0].songIds, ["a", "b"])
        XCTAssertEqual(rows[0].pathsNotInLibrary, ["/gone.flac"])
    }

    /// `POST /v1/pairing/redeem` exchanges a one-time QR secret for a device-specific token.
    func testRedeemPairingSecretPostsSecretDeviceIdAndDisplayName() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertTrue(req.url?.path.contains("v1/pairing/redeem") ?? false)
            let body = try XCTUnwrap(req.httpBodyStreamOrBody())
            let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(obj?["secret"] as? String, "one-time-secret")
            XCTAssertEqual(obj?["deviceId"] as? String, "device-1")
            XCTAssertEqual(obj?["displayName"] as? String, "iPhone")
            let data = #"{"deviceId":"device-1","token":"issued-token"}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let result = try await RemoteAPIClient.redeemPairingSecret(
            baseURLString: "http://127.0.0.1:8765",
            secret: "one-time-secret",
            deviceId: "device-1",
            displayName: "iPhone",
            session: sessionWithMock()
        )
        XCTAssertEqual(result.deviceId, "device-1")
        XCTAssertEqual(result.token, "issued-token")
    }

    func testRedeemPairingSecretThrowsOnInvalidSecret() async throws {
        MockURLProtocol.handler = { req in
            let data = #"{"error":{"code":"unauthorized","message":"invalid or expired secret"}}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        do {
            _ = try await RemoteAPIClient.redeemPairingSecret(
                baseURLString: "http://127.0.0.1:8765",
                secret: "stale",
                deviceId: "device-1",
                displayName: "iPhone",
                session: sessionWithMock()
            )
            XCTFail("expected an error")
        } catch RemoteAPIError.server(let code, let message) {
            XCTAssertEqual(code, "unauthorized")
            XCTAssertEqual(message, "invalid or expired secret")
        }
    }
}

private extension URLRequest {
    /// `MockURLProtocol` receives the request after `URLSession` has moved the body into
    /// `httpBodyStream` for POST requests; this reads it back into `Data` for assertions.
    func httpBodyStreamOrBody() throws -> Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read < 0 { break }
            if read == 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
