import AVFoundation
import XCTest
@testable import UX_Music_Mobile

@MainActor
final class LoudnessNormalisationTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func session(payload: String, status: Int = 200) -> URLSession {
        MockURLProtocol.handler = { request in
            let body = request.url?.path == "/v1/remote/songs" ? "[]" : payload
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testFetchLoudnessAcceptsCurrentAndLegacyEntriesWithOriginalSongIDs() async throws {
        let session = session(payload: #"{"/Music/曲.flac":{"loudness":-24,"truePeak":-2.5},"uuid-track":-12.5,"pending":{},"invalid":{"loudness":"unknown"}}"#)
        defer { session.invalidateAndCancel() }
        let client = RemoteAPIClient(baseURLString: "http://desktop.invalid:8765", session: session)

        let map = try await client.fetchLoudness()

        XCTAssertEqual(map, ["/Music/曲.flac": -24, "uuid-track": -12.5])
    }

    func testFetchLoudnessRejectsHTTPFailureInsteadOfReturningAnEmptyMap() async {
        let session = session(payload: "{}", status: 401)
        defer { session.invalidateAndCancel() }
        let client = RemoteAPIClient(baseURLString: "http://desktop.invalid:8765", session: session)
        do {
            _ = try await client.fetchLoudness()
            XCTFail("Expected an HTTP error")
        } catch {
            guard case RemoteAPIError.httpStatus(401) = error else {
                return XCTFail("Expected HTTP 401, received \(error)")
            }
        }
    }

    func testBothRefreshPathsRestoreLoudnessForOfflineDownloadedPlayback() async throws {
        let suiteName = "LoudnessNormalisationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let originalConfig = UserDefaults.standard.data(forKey: AppConstants.serverConfigKey)
        defer { UserDefaults.standard.set(originalConfig, forKey: AppConstants.serverConfigKey) }
        let session = session(payload: #"{"/Music/曲.flac":{"loudness":-24,"truePeak":-2.5}}"#)
        defer { session.invalidateAndCancel() }

        for refreshLibrary in [true, false] {
            defaults.removePersistentDomain(forName: suiteName)
            let model = AppModel(loudnessDefaults: defaults)
            model.urlSession = session
            model.serverConfig = ServerConfig(host: "desktop.invalid", port: 8765)
            if refreshLibrary {
                await model.refreshLibrary()
            } else {
                await model.refreshLoudnessOnly()
            }
            XCTAssertEqual(model.player.loudnessMap["/Music/曲.flac"], -24)

            // Relaunch without any network request; a downloaded file rewrites only the path.
            let restored = AppModel(loudnessDefaults: defaults)
            let song = Song(id: "/Music/曲.flac", path: "/Music/曲.flac")
                .withPath("/DownloadedTracks/hashed-file.flac")
            restored.player.configureForPreview(song: song, isPlaying: false, positionSeconds: 0, durationSeconds: 1)
            restored.player.refreshVolumeForCurrentSong()

            XCTAssertEqual(restored.loudness[song.id], -24)
            XCTAssertEqual(restored.player.normalisationGainDecibelsForTesting, 6, accuracy: 0.001)
        }
    }

    func testFailedRefreshRetainsPersistedLoudness() async throws {
        let suiteName = "LoudnessNormalisationTests.failure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder().encode(["track": -12.0]), forKey: AppConstants.loudnessCacheKey)
        let session = session(payload: "{}", status: 401)
        defer { session.invalidateAndCancel() }
        let model = AppModel(loudnessDefaults: defaults)
        model.urlSession = session

        await model.refreshLoudnessOnly()

        XCTAssertEqual(model.player.loudnessMap["track"], -12)
        XCTAssertEqual(AppModel(loudnessDefaults: defaults).player.loudnessMap["track"], -12)
    }

    func testNativeGainIsIndependentOfMasterVolumeAndEqualiser() {
        let keys = ["uxmusic.equaliser.enabled", "uxmusic.equaliser.preamp", "uxmusic.equaliser.bands", "uxmusic.equaliser.presetName"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
        }
        let player = MusicPlayerService()
        player.setEqualiserEnabled(false)
        player.targetLoudness = -18
        player.loudnessMap = ["quiet": -24, "loud": -12]
        player.configureForPreview(song: Song(id: "quiet", path: "/DownloadedTracks/hash.flac"), isPlaying: false, positionSeconds: 0, durationSeconds: 1)
        player.refreshVolumeForCurrentSong()

        XCTAssertEqual(player.normalisationGainDecibelsForTesting, 6, accuracy: 0.001)
        player.masterVolume = 0.4
        player.refreshVolumeForCurrentSong()
        XCTAssertEqual(player.masterOutputVolumeForTesting, 0.4, accuracy: 0.001)
        XCTAssertEqual(player.normalisationGainDecibelsForTesting, 6, accuracy: 0.001)
        player.resetEqualiserToFlat()
        XCTAssertEqual(player.normalisationGainDecibelsForTesting, 6, accuracy: 0.001)

        player.configureForPreview(song: Song(id: "loud", path: "/DownloadedTracks/other.flac"), isPlaying: false, positionSeconds: 0, durationSeconds: 1)
        player.refreshVolumeForCurrentSong()
        XCTAssertEqual(player.normalisationGainDecibelsForTesting, -6, accuracy: 0.001)
        player.loudnessMap["loud"] = -9
        XCTAssertEqual(player.normalisationGainDecibelsForTesting, -9, accuracy: 0.001)
        player.targetLoudness = -20
        XCTAssertEqual(player.normalisationGainDecibelsForTesting, -11, accuracy: 0.001)
        player.normaliseEnabled = false
        XCTAssertEqual(player.normalisationGainDecibelsForTesting, 0, accuracy: 0.001)
    }

    func testNativeGainRemainsInSignalPathAfterGraphRebuild() async throws {
        let player = MusicPlayerService()
        defer { player.stop() }
        player.targetLoudness = -18
        player.loudnessMap = ["quiet": -24]
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }

        for sampleRate in [44_100.0, 48_000.0] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            files.append(url)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)))
            buffer.frameLength = buffer.frameCapacity
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) { channels[channel][frame] = 0 }
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let song = Song(id: "quiet", path: url.path)

            await player.play(song, newQueue: [song])

            XCTAssertTrue(player.hasActiveLocalAudioFileForTesting)
            XCTAssertTrue(player.normalisationIsInSignalPathForTesting)
            XCTAssertEqual(player.normalisationGainDecibelsForTesting, 6, accuracy: 0.001)
        }
    }

    func testGainFormulaMissingDataAndExistingBoostLimit() {
        let map = ["quiet": -24.0, "loud": -12, "veryQuiet": -60]
        XCTAssertEqual(LoudnessNormalisation.linearGain(songID: "quiet", map: map, target: -18, enabled: true), pow(10, 6.0 / 20), accuracy: 0.0001)
        XCTAssertEqual(LoudnessNormalisation.linearGain(songID: "loud", map: map, target: -18, enabled: true), pow(10, -6.0 / 20), accuracy: 0.0001)
        XCTAssertEqual(LoudnessNormalisation.linearGain(songID: "veryQuiet", map: map, target: -18, enabled: true), 4)
        XCTAssertEqual(LoudnessNormalisation.linearGain(songID: "quiet", map: map, target: -18, enabled: false), 1)
        XCTAssertEqual(LoudnessNormalisation.linearGain(songID: "missing", map: map, target: -18, enabled: true), 1)
        XCTAssertEqual(LoudnessNormalisation.linearGain(songID: nil, map: map, target: -18, enabled: true), 1)
    }
}

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

    // MARK: - RemoteAPIClient.downloadFileQueryItems (real production code, not re-derived in the test)

    func testDownloadFileQueryItemsOriginalOmitsBitrateAndAddsSource() {
        let items = RemoteAPIClient.downloadFileQueryItems(songId: "track-1", preferOriginalAudio: true, aacBitrateKbps: 256)
        XCTAssertEqual(items, [
            URLQueryItem(name: "id", value: "track-1"),
            URLQueryItem(name: "source", value: "original"),
        ])
    }

    func testDownloadFileQueryItemsAACIncludesBitrateNotSource() {
        let items = RemoteAPIClient.downloadFileQueryItems(songId: "track-1", preferOriginalAudio: false, aacBitrateKbps: 192)
        XCTAssertEqual(items, [
            URLQueryItem(name: "id", value: "track-1"),
            URLQueryItem(name: "bitrate", value: "192"),
        ])
    }

    // MARK: - RemoteAPIClient.songStreamQueryItems / songStreamRequest (Task A stream-first playback)

    func testSongStreamQueryItemsRequestsAACStream() {
        let items = RemoteAPIClient.songStreamQueryItems(songId: "track-1")
        XCTAssertEqual(items, [
            URLQueryItem(name: "id", value: "track-1"),
            URLQueryItem(name: "stream", value: "aac"),
        ])
    }

    func testSongStreamRequestBuildsFileEndpointWithBearerHeader() throws {
        let client = RemoteAPIClient(baseURLString: "http://192.168.0.5:8765", token: "secret-token")
        let request = try client.songStreamRequest(songId: "track-1")
        XCTAssertEqual(request.url?.path, "/v1/remote/file")
        XCTAssertTrue(request.url?.query?.contains("stream=aac") == true)
        XCTAssertTrue(request.url?.query?.contains("id=track-1") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
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

    /// The desktop reads an optional `X-Device-Name` header on authenticated LAN requests to
    /// self-report a display name for devices paired before display-name support existed (see
    /// `DeviceIdentity.displayName`). URLSession passes non-ASCII header values through unmodified
    /// (verified empirically), so no percent-encoding is needed — the raw name is sent as-is.
    func testPingSendsDeviceNameHeader() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Device-Name"), "Yukiの iPhone")
            let data = #"{"hostname":"desk"}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let client = RemoteAPIClient(
            baseURLString: "http://127.0.0.1:8765",
            deviceName: "Yukiの iPhone",
            session: sessionWithMock()
        )
        _ = try await client.ping()
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

    func testDecodeRemoteLyricsPayloadWithTranslation() throws {
        let json = Data(
            #"{"found":true,"type":"lrc","content":"[00:01.00]Hi","translationContent":"[00:01.00]やあ","translationFormat":"lrc"}"#.utf8
        )
        let p = try JSONDecoder().decode(RemoteLyricsPayload.self, from: json)
        XCTAssertEqual(p.translationContent, "[00:01.00]やあ")
        XCTAssertEqual(p.translationFormat, "lrc")
    }

    /// Older desktops without the 和訳 extension omit the translation keys entirely — must still decode.
    func testDecodeRemoteLyricsPayloadWithoutTranslationKeysStillDecodes() throws {
        let json = Data(#"{"found":true,"type":"txt","content":"Hi"}"#.utf8)
        let p = try JSONDecoder().decode(RemoteLyricsPayload.self, from: json)
        XCTAssertNil(p.translationContent)
        XCTAssertNil(p.translationFormat)
    }

    func testFetchSituationPlaylistsDecodesOrderedArray() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url?.path.contains("v1/remote/situation-playlists") ?? false)
            let data = Data(
                #"[{"name":"最近追加した曲","songIds":["a"]},{"name":"よく聴く曲","songIds":["b","c"]},{"name":"ランダムピック","songIds":[]}]"#.utf8
            )
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: sessionWithMock())
        let rows = try await client.fetchSituationPlaylists()
        XCTAssertEqual(rows.map(\.name), ["最近追加した曲", "よく聴く曲", "ランダムピック"])
        XCTAssertEqual(rows[1].songIds, ["b", "c"])
    }

    func testFetchSituationPlaylistsThrowsHTTPStatusOn404() async throws {
        MockURLProtocol.handler = { req in
            let res = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (Data(), res)
        }
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: sessionWithMock())
        do {
            _ = try await client.fetchSituationPlaylists()
            XCTFail("expected an error")
        } catch RemoteAPIError.httpStatus(let code) {
            XCTAssertEqual(code, 404)
        }
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

    func testSendPlaySongCommandPostsActionAndSongId() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertTrue(req.url?.path.contains("v1/remote/command") ?? false)
            let body = try XCTUnwrap(req.httpBodyStreamOrBody())
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(obj["action"], "play-song")
            XCTAssertEqual(obj["songId"], "song-1")
            let data = #"{"ok":true}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: sessionWithMock())
        try await client.sendPlaySongCommand(songId: "song-1")
    }

    /// Headless host case (`progress/remote-play-song.md`): the desktop returns 409 with the
    /// dedicated `gui_required` code when it has no Wails runtime to route playback through.
    func testSendPlaySongCommandThrowsGuiRequiredOnHeadlessHost() async throws {
        MockURLProtocol.handler = { req in
            let data = #"{"error":{"code":"gui_required","message":"GUI is required to play songs"}}"#.data(using: .utf8)!
            let res = HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!
            return (data, res)
        }
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: sessionWithMock())
        do {
            try await client.sendPlaySongCommand(songId: "song-1")
            XCTFail("expected an error")
        } catch RemoteAPIError.server(let code, _) {
            XCTAssertEqual(code, "gui_required")
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

/// `set-shuffle` / `set-loop` / `queue-jump` と `/v1/remote/queue`（409 `queue_unavailable` / `queue_changed` を型付きで返す）。
final class RemoteQueueAPIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func client(status: Int = 200, body: String = #"{"ok":true}"#, capture: ((URLRequest, [String: Any]?) -> Void)? = nil) -> (RemoteAPIClient, URLSession) {
        MockURLProtocol.handler = { request in
            var json: [String: Any]?
            if let data = request.httpBody ?? request.httpBodyStream.flatMap({ stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: 1024); if n <= 0 { break }; data.append(buf, count: n) }
                return data
            }) {
                json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            capture?(request, json)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return (RemoteAPIClient(baseURLString: "http://desktop.invalid:8765", session: session), session)
    }

    func testSetShuffleBody() async throws {
        var captured: [String: Any]?
        let (c, s) = client { _, json in captured = json }
        defer { s.invalidateAndCancel() }
        try await c.sendQueueCommand(action: "set-shuffle", intValue: 1)
        XCTAssertEqual(captured?["action"] as? String, "set-shuffle")
        XCTAssertEqual(captured?["value"] as? Int, 1)
    }

    func testSetLoopBody() async throws {
        var captured: [String: Any]?
        let (c, s) = client { _, json in captured = json }
        defer { s.invalidateAndCancel() }
        try await c.sendQueueCommand(action: "set-loop", mode: "one")
        XCTAssertEqual(captured?["action"] as? String, "set-loop")
        XCTAssertEqual(captured?["mode"] as? String, "one")
        XCTAssertNil(captured?["value"])
    }

    func testQueueJumpBody() async throws {
        var captured: [String: Any]?
        let (c, s) = client { _, json in captured = json }
        defer { s.invalidateAndCancel() }
        try await c.sendQueueCommand(action: "queue-jump", intValue: 4, songId: "song-4")
        XCTAssertEqual(captured?["action"] as? String, "queue-jump")
        XCTAssertEqual(captured?["value"] as? Int, 4)
        XCTAssertEqual(captured?["songId"] as? String, "song-4")
    }

    func test409QueueUnavailableIsTyped() async {
        let (c, s) = client(status: 409, body: #"{"error":{"code":"queue_unavailable","message":"x"}}"#)
        defer { s.invalidateAndCancel() }
        do {
            try await c.sendQueueCommand(action: "set-shuffle", intValue: 1)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? RemoteQueueError, .unavailable)
        }
    }

    func test409QueueChangedIsTyped() async {
        let (c, s) = client(status: 409, body: #"{"error":{"code":"queue_changed","message":"x"}}"#)
        defer { s.invalidateAndCancel() }
        do {
            try await c.sendQueueCommand(action: "queue-jump", intValue: 1, songId: "a")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? RemoteQueueError, .changed)
        }
    }

    func testOtherErrorsStayRemoteAPIError() async {
        let (c, s) = client(status: 400, body: #"{"error":{"code":"bad_request","message":"bad"}}"#)
        defer { s.invalidateAndCancel() }
        do {
            try await c.sendQueueCommand(action: "set-loop", mode: "zzz")
            XCTFail("expected throw")
        } catch RemoteAPIError.server(let code, _) {
            XCTAssertEqual(code, "bad_request")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFetchQueueParsesAndHitsQueuePath() async throws {
        var path: String?
        let (c, s) = client(body: #"{"available":true,"shuffled":false,"loopMode":"off","index":0,"items":[{"id":"a","title":"A"}]}"#) { req, _ in path = req.url?.path }
        defer { s.invalidateAndCancel() }
        let queue = try await c.fetchQueue()
        XCTAssertEqual(path, "/v1/remote/queue")
        XCTAssertEqual(queue.items.map(\.id), ["a"])
    }

    func testFetchQueue409Unavailable() async {
        let (c, s) = client(status: 409, body: #"{"error":{"code":"queue_unavailable","message":"x"}}"#)
        defer { s.invalidateAndCancel() }
        do {
            _ = try await c.fetchQueue()
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? RemoteQueueError, .unavailable)
        }
    }
}
