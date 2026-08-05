import XCTest
@testable import UX_Music_Mobile

private final class LibraryFeaturesMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, URLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = LibraryFeaturesMockURLProtocol.handler else {
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
final class AppModelLibraryFeaturesTests: XCTestCase {
    override func tearDown() {
        LibraryFeaturesMockURLProtocol.handler = nil
        UserDefaults.standard.removeObject(forKey: AppConstants.librarySortOrderKey)
        super.tearDown()
    }

    private func sessionWithMock() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibraryFeaturesMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - librarySortOrder persistence

    func testLibrarySortOrderDefaultsToAlbum() {
        UserDefaults.standard.removeObject(forKey: AppConstants.librarySortOrderKey)
        let model = AppModel()
        XCTAssertEqual(model.librarySortOrder, .album)
    }

    func testLibrarySortOrderPersistsAcrossInstances() {
        UserDefaults.standard.removeObject(forKey: AppConstants.librarySortOrderKey)
        let model = AppModel()
        model.librarySortOrder = .artist
        let reloaded = AppModel()
        XCTAssertEqual(reloaded.librarySortOrder, .artist)
    }

    // MARK: - refreshSituationPlaylists

    func testRefreshSituationPlaylistsLoadsOrderedList() async throws {
        let model = AppModel()
        model.urlSession = sessionWithMock()
        model.serverConfig = ServerConfig(host: "127.0.0.1", port: 8765)

        LibraryFeaturesMockURLProtocol.handler = { req in
            let data = Data(#"[{"name":"最近追加した曲","songIds":["a"]}]"#.utf8)
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }

        await model.refreshSituationPlaylists()
        XCTAssertEqual(model.situationPlaylists.map(\.name), ["最近追加した曲"])
    }

    func testRefreshSituationPlaylistsGracefullyEmptyOn404() async throws {
        let model = AppModel()
        model.urlSession = sessionWithMock()
        model.serverConfig = ServerConfig(host: "127.0.0.1", port: 8765)

        LibraryFeaturesMockURLProtocol.handler = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), res)
        }

        await model.refreshSituationPlaylists()
        XCTAssertEqual(model.situationPlaylists, [])
    }

    // MARK: - localBilingualLyricsDisplay

    func testLocalBilingualLyricsDisplayMergesSyncedLyricsWithJaLRC() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uxm-bilingual-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LyricsFileStore(fileManager: .default, lyricsDirectoryOverride: dir)
        let model = AppModel(lyricsFileStore: store)
        let sid = "song-\(UUID().uuidString)"
        try store.saveLyrics("[00:01.00]Hello", wearType: "lrc", songId: sid)
        try store.saveTranslation("[00:01.00]こんにちは", translationFormat: "lrc", songId: sid)

        guard case .synced(let lines)? = model.localBilingualLyricsDisplay(for: sid) else {
            XCTFail("expected synced mode")
            return
        }
        XCTAssertEqual(lines.map(\.translation), ["こんにちは"])
    }

    func testLocalBilingualLyricsDisplayReturnsNilWhenNoLyrics() {
        let model = AppModel()
        XCTAssertNil(model.localBilingualLyricsDisplay(for: "missing"))
    }
}
