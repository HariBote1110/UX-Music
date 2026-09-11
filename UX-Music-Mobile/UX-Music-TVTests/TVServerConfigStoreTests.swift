import XCTest
@testable import UX_Music_TV

private final class TVFailoverMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, URLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
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

/// Token persistence tests, using an isolated `UserDefaults` suite (never the real
/// `UserDefaults.standard`) so they can run repeatedly without leaking state.
final class TVServerConfigStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TVServerConfigStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        TVFailoverMockURLProtocol.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLoadWithoutPriorSaveReturnsUnconfiguredDefault() {
        let store = TVServerConfigStore(defaults: defaults)
        let config = store.load()
        XCTAssertFalse(config.isConfigured)
        XCTAssertEqual(config.token, "")
    }

    func testSaveThenLoadRoundTripsHostPortAndToken() {
        let store = TVServerConfigStore(defaults: defaults)
        let config = ServerConfig(
            host: "192.168.1.10",
            port: 8765,
            token: "tv-token-abc",
            serverDeviceId: "desktop-1"
        )

        store.save(config)
        let loaded = store.load()

        XCTAssertEqual(loaded.host, "192.168.1.10")
        XCTAssertEqual(loaded.port, 8765)
        XCTAssertEqual(loaded.token, "tv-token-abc")
        XCTAssertEqual(loaded.serverDeviceId, "desktop-1")
    }

    func testClearRemovesPersistedConfig() {
        let store = TVServerConfigStore(defaults: defaults)
        store.save(ServerConfig(host: "192.168.1.10", port: 8765, token: "tv-token-abc"))

        store.clear()

        XCTAssertFalse(store.load().isConfigured)
    }

    @MainActor
    func testTVWithFailoverRecoversStalePortAndPersistsIt() async throws {
        let store = TVServerConfigStore(defaults: defaults)
        store.save(ServerConfig(
            host: "desktop.invalid",
            port: 8765,
            token: "stored-token",
            serverDeviceId: "desktop-1"
        ))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TVFailoverMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let model = TVAppModel(store: store, urlSession: session)

        TVFailoverMockURLProtocol.handler = { request in
            let port = request.url?.port
            if request.url?.path == "/v1/remote/state", port == 8765 {
                throw URLError(.cannotConnectToHost)
            }
            if request.url?.path == "/v1/identity", port == 8766 {
                let data = #"{"deviceId":"desktop-1","hostname":"desk","roles":["gui"]}"#.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
            if request.url?.path == "/v1/remote/state", port == 8766 {
                XCTAssertEqual(store.load().port, 8766)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("{}".utf8), response)
            }
            throw URLError(.cannotConnectToHost)
        }

        await model.prepareStoredConnection()

        XCTAssertEqual(model.serverConfig.port, 8766)
        XCTAssertEqual(store.load().port, 8766)
        XCTAssertTrue(model.isStoredConnectionReady)
    }
}
