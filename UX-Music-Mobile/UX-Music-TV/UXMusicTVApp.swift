import SwiftUI

/// Entry point for the tvOS app. Phase 1-2 scope: mDNS discovery + pairing
/// (`TVRootView`). Browsing/playback UI land in later phases (see
/// `markdown/appletv-servermode-plan.md`, Phase 1-3 onward).
@main
struct UXMusicTVApp: App {
    #if DEBUG
    /// Started once, on first access, from `init()` below — see `MainThreadWatchdog`'s doc comment
    /// (`progress/tvos-playback-concurrency.md` "DEBUG watchdog" 追記) for why this exists: a real-
    /// device way to catch the audit's deferred rank 3/4 hazards (or anything else) actually
    /// blocking the main thread, rather than only reasoning about it statically.
    private static let mainThreadWatchdog: MainThreadWatchdog = {
        let watchdog = MainThreadWatchdog()
        watchdog.start()
        return watchdog
    }()

    init() {
        _ = Self.mainThreadWatchdog // force the lazy static initializer (and thus `start()`) to run
    }
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // DEBUG-only preview harness (`progress/tvos-design.md`): launching with
            // `UXTV_PREVIEW=nowplaying|nowplayingambient|browse|albumdetail` (e.g. via
            // `SIMCTL_CHILD_UXTV_PREVIEW=nowplaying xcrun simctl launch …`) renders a screen with
            // rich stub data, no pairing/network required, so the cinematic design can be
            // screenshotted directly in the simulator.
            switch ProcessInfo.processInfo.environment["UXTV_PREVIEW"] {
            case "nowplaying":
                TVNowPlayingPreviewHarness()
            case "nowplayingambient":
                TVNowPlayingAmbientPreviewHarness()
            case "browse":
                TVBrowsePreviewHarness()
            case "albumdetail":
                TVLibraryDetailPreviewHarness()
            case "youtubebadge":
                TVYouTubeBadgePreviewHarness()
            case "detailplay":
                TVDetailPlayPreviewHarness()
            case "relay":
                TVRelayStreamPreviewHarness()
            case "livenowplaying":
                TVLiveNowPlayingHarness()
            case "songstream":
                TVSongStreamPreviewHarness()
            default:
                TVRootView()
            }
            #else
            TVRootView()
            #endif
        }
    }
}

#if DEBUG
/// DEBUG-only harness for driving `TVRelayStreamPlayer` end-to-end against a real (or mock) relay
/// endpoint without pairing UI, used by the sim E2E verification in
/// `progress/tvos-relay-reception.md`. Reads `UXTV_RELAY_HOST`/`UXTV_RELAY_PORT`/
/// `UXTV_RELAY_TOKEN` (`SIMCTL_CHILD_`-prefixed via `xcrun simctl launch`) and immediately starts
/// `TVRelayPlaybackController.start()`. The `[RelayStream] rendering rms=` log lines
/// (`TVRelayStreamPlayer`, DEBUG-only) are what the harness's caller greps out of
/// `xcrun simctl spawn ... log stream` to confirm real, non-silent decoded audio.
/// DEBUG-only harness for `UXTV_PREVIEW=detailplay`, reproducing the dead-Now-Playing regression
/// (`progress/tvos-design.md`): renders `TVLibraryDetailView` under the SAME `TVBrowsePresentation`
/// single-cover mechanism `TVBrowseView` uses, then programmatically triggers a track selection
/// (mirroring the manual path: user taps a track row) shortly after appearing. `MusicPlayerService`
/// is put in preview mode via `configureForPreview` (never touches the audio engine — no sound in
/// the simulator) with a stub song and non-zero progress, standing in for a completed
/// `TVPlaybackController.play(_:queue:)` call. If the regression's cover-on-cover race were still
/// present, this would leave the screen on the detail view or a blank cover; with the fix, it
/// settles on Now Playing showing the stub track's title and advancing progress.
struct TVDetailPlayPreviewHarness: View {
    @State private var presentation: TVBrowsePresentation? = .detail(Self.content)
    private let player = MusicPlayerService()
    private let client = RemoteAPIClient(baseURLString: "http://198.51.100.1:9999")

    private static let stubSong = Song(
        id: "stub-1", path: "", title: "検証用スタブ曲", artist: "UX Music Demo", artworkId: "preview-1"
    )
    private static let content = TVLibraryDetailContent(
        id: "preview-detailplay",
        title: "デモアルバム",
        artist: "UX Music Demo",
        artworkId: "preview-1",
        songs: [stubSong]
    )

    var body: some View {
        Group {
            switch presentation {
            case .detail(let content):
                TVLibraryDetailView(content: content, client: client, onPlay: simulateTrackSelection)
            case .nowPlaying:
                TVNowPlayingView(player: player, client: client)
            case .relay, .remotePlaySong, .none:
                EmptyView()
            }
        }
        .task {
            // Simulate the user selecting the stub track shortly after the detail screen appears
            // — the manual path is tapping a `TVTrackRow` (or the header's 「再生」 button), both
            // of which call this same `onPlay` closure in production (`TVLibraryDetailView.swift`).
            try? await Task.sleep(nanoseconds: 400_000_000)
            simulateTrackSelection(Self.stubSong, [Self.stubSong])
        }
    }

    /// Stands in for `TVBrowseView.play(_:queue:)`: configures the (silent, preview-mode) player
    /// with the selected track and switches the single-cover `presentation` state straight from
    /// `.detail` to `.nowPlaying`, exactly as production code does after `TVPlaybackController.play`
    /// completes.
    private func simulateTrackSelection(_ song: Song, _ queue: [Song]) {
        player.configureForPreview(song: song, isPlaying: true, positionSeconds: 12, durationSeconds: 180)
        presentation = .nowPlaying
    }
}

struct TVRelayStreamPreviewHarness: View {
    @StateObject private var controller: TVRelayPlaybackController

    init() {
        let env = ProcessInfo.processInfo.environment
        let host = env["UXTV_RELAY_HOST"] ?? "127.0.0.1"
        let port = env["UXTV_RELAY_PORT"] ?? "8765"
        let token = env["UXTV_RELAY_TOKEN"] ?? ""
        let client = RemoteAPIClient(baseURLString: "http://\(host):\(port)", token: token)
        _controller = StateObject(wrappedValue: TVRelayPlaybackController(client: client))
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("TVRelayStreamPreviewHarness")
                .font(.headline)
            Text("isPlaying=\(controller.isPlaying)")
            Text("state=\(String(describing: controller.state))")
        }
        .padding(48)
        .onAppear { controller.start() }
    }
}

/// DEBUG-only harness for the real (non-preview) local-song playback + Now Playing pipeline,
/// used to verify the tap→firstAudio latency fix (`TVPlaybackController.play`, see
/// `progress/tvos-playback.md`) and that `TVNowPlayingView`'s progress bar genuinely advances
/// during live playback (`progress/tvos-nowplaying.md`) — as opposed to `TVDetailPlayPreviewHarness`,
/// which only exercises `configureForPreview`'s static stub values.
///
/// Reads `UXTV_LIVE_HOST`/`UXTV_LIVE_PORT`/`UXTV_LIVE_TOKEN`/`UXTV_LIVE_SONG_ID`
/// (`SIMCTL_CHILD_`-prefixed via `xcrun simctl launch`), fetches the real queue from
/// `/v1/remote/songs`, mutes `MusicPlayerService.masterVolume` (no sound in the simulator), and
/// drives `TVPlaybackController.play` exactly as `TVBrowseView.play(_:queue:)` does in production,
/// then presents the real `TVNowPlayingView` (not a stub).
struct TVLiveNowPlayingHarness: View {
    @StateObject private var playbackController: TVPlaybackController
    private let player = MusicPlayerService()
    private let client: RemoteAPIClient
    private let songId: String?

    init() {
        let env = ProcessInfo.processInfo.environment
        let host = env["UXTV_LIVE_HOST"] ?? "127.0.0.1"
        let port = env["UXTV_LIVE_PORT"] ?? "8765"
        let token = env["UXTV_LIVE_TOKEN"] ?? ""
        let apiClient = RemoteAPIClient(baseURLString: "http://\(host):\(port)", token: token)
        client = apiClient
        songId = env["UXTV_LIVE_SONG_ID"]
        let sharedPlayer = player
        sharedPlayer.masterVolume = 0 // muted per verification convention — never audible in the simulator
        _playbackController = StateObject(wrappedValue: TVPlaybackController(client: apiClient, player: sharedPlayer))
    }

    var body: some View {
        TVNowPlayingView(player: player, client: client)
            .task {
                guard let songId else { return }
                do {
                    let songs = try await client.fetchSongs()
                    guard let songIdx = songs.firstIndex(where: { $0.id == songId }) else { return }
                    // Realistic prefetch window (current + next 2, matching TVPlaybackController's
                    // default `prefetchCount`), NOT a single-song queue — the ordering bug this
                    // harness verifies only shows up when there is something to prefetch.
                    let queue = Array(songs[songIdx..<min(songs.count, songIdx + 3)])
                    await playbackController.play(queue[0], queue: queue)
                } catch {
                    NSLog("[TVLiveNowPlayingHarness] fetchSongs/play failed: %@", String(describing: error))
                }
            }
    }
}

/// DEBUG-only harness for `UXTV_PREVIEW=songstream` — exercises Task A's stream-first path
/// (`TVPlaybackController.play` cache-miss branch → `TVSongStreamController` →
/// `TVRelayStreamPlayer`) end to end against the bundled `relay-sample.aac` fixture served through
/// a mock `URLProtocol`, so it needs no live host. Used to verify both halves of this task's fix:
/// (1) `TVNowPlayingView` shows title/artwork/progress from the very first streamed frame (the
/// "empty Now Playing during streaming" defect — see `MusicPlayerService`'s "External playback
/// bridging" section), and (2) playing the SAME song twice in a row (start → stop → start, the
/// crash repro's exact ordering) no longer crashes (`TVRelayStreamPlayer.engineQueue`'s
/// synchronisation fix). `UXTV_SONGSTREAM_REPLAY=1` drives the second half automatically: after
/// the first stream starts rendering, it waits briefly, calls `play` again for the SAME song
/// (forcing `streamController.stop()` then a fresh `start()`), and logs
/// `[SongStreamHarness] replay ok` once the second stream also starts rendering — the crash, if
/// the fix regressed, would terminate the process before that log line appears.
struct TVSongStreamPreviewHarness: View {
    @StateObject private var playbackController: TVPlaybackController
    private let player = MusicPlayerService()
    private let client: RemoteAPIClient
    private static let song = Song(
        id: "songstream-demo", path: "", title: "ストリーム検証曲", artist: "UX Music Demo", artworkId: "preview-1"
    )

    init() {
        UXTVSongStreamMockURLProtocol.register()
        // `UXTV_SONGSTREAM_LYRICS` (`none|empty|lrc`, default `none`) drives the mock's
        // `/v1/remote/lyrics` response so this harness can exercise `TVNowPlayingView`'s lyrics
        // states while running the REAL stream-first path end to end (`progress/tvos-nowplaying-textcolumn.md`)
        // — unlike a bare `RemoteLyricsPayload` handed straight to `TVNowPlayingLyricsLayout`, this
        // goes through `MusicPlayerService.beginExternalPlayback` → `.task(id:)` → `loadLyrics()`
        // exactly like the real device does.
        UXTVSongStreamMockURLProtocol.lyricsVariant = ProcessInfo.processInfo.environment["UXTV_SONGSTREAM_LYRICS"] ?? "none"
        // Loopback port normally unreachable, but `UXTVSongStreamMockURLProtocol` now also serves
        // `/v1/remote/lyrics` (see above), so `fetchLyrics` succeeds via the mock rather than
        // failing fast — everything else (`fetchLoudness()`/background cache download) still fails
        // fast against the real unreachable port, as before.
        let apiClient = RemoteAPIClient(
            baseURLString: "http://127.0.0.1:1",
            session: URLSession(configuration: UXTVSongStreamMockURLProtocol.sessionConfiguration())
        )
        client = apiClient
        let sharedPlayer = player
        sharedPlayer.masterVolume = 0 // muted per verification convention — never audible in the simulator
        let cache = TVPlaybackCacheStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("songstream-harness-\(UUID().uuidString)"),
            downloader: { _, _ in throw URLError(.cannotConnectToHost) }
        )
        _playbackController = StateObject(wrappedValue: TVPlaybackController(
            client: apiClient,
            player: sharedPlayer,
            cache: cache,
            streamPlayerFactory: { TVRelayStreamPlayer(sessionConfiguration: UXTVSongStreamMockURLProtocol.sessionConfiguration(), muteOutput: true) }
        ))
    }

    var body: some View {
        TVNowPlayingView(player: player, client: client)
            .task {
                await playbackController.play(Self.song, queue: [Self.song])
                guard ProcessInfo.processInfo.environment["UXTV_SONGSTREAM_REPLAY"] == "1" else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                NSLog("[SongStreamHarness] replaying same song")
                await playbackController.play(Self.song, queue: [Self.song])
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                NSLog("[SongStreamHarness] replay ok")
            }
    }
}

/// Serves the bundled `relay-sample.aac` fixture, chunked, for any request whose path is
/// `/v1/remote/file` — matching `RemoteAPIClient.songStreamRequest`'s route — so
/// `TVSongStreamPreviewHarness` can drive a real stream end to end with no live host. Mirrors
/// `TVRelayStreamPlayerLifecycleTests`'s `ChunkedFixtureURLProtocol` (test target can't share code
/// with the app target, hence the duplication).
final class UXTVSongStreamMockURLProtocol: URLProtocol {
    /// `none|empty|lrc` — see `TVSongStreamPreviewHarness.init`'s doc comment. `none` answers
    /// `found: false` (mirrors "no lyrics on the server"), `empty` answers `found: true` with an
    /// empty `.lrc` body (parses to zero timed lines), `lrc` answers a real multi-line `.lrc` body.
    static var lyricsVariant = "none"

    static func register() {
        URLProtocol.registerClass(UXTVSongStreamMockURLProtocol.self)
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UXTVSongStreamMockURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/v1/remote/file" || request.url?.path == "/v1/remote/lyrics"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/v1/remote/lyrics" {
            startLoadingLyrics()
            return
        }
        guard let fixtureURL = Bundle.main.url(forResource: "relay-sample", withExtension: "aac"),
              let data = try? Data(contentsOf: fixtureURL)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://mock.invalid")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "audio/aac"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let chunkSize = 4096
        var offset = 0
        DispatchQueue.global().async { [weak self] in
            while offset < data.count {
                guard let self else { return }
                let end = min(offset + chunkSize, data.count)
                self.client?.urlProtocol(self, didLoad: data.subdata(in: offset..<end))
                offset = end
                usleep(2000)
            }
            self?.client?.urlProtocolDidFinishLoading(self!)
        }
    }

    private func startLoadingLyrics() {
        let body: [String: Any?]
        switch Self.lyricsVariant {
        case "empty":
            body = ["found": true, "type": "lrc", "content": ""]
        case "lrc":
            let lrc = """
            [00:00.00]夜が明ける前に
            [00:10.00]この歌を君に届けたい
            [00:20.00]繋がっていると感じられるように
            """
            body = ["found": true, "type": "lrc", "content": lrc]
        default: // "none"
            body = ["found": false, "type": nil, "content": nil]
        }
        let data = try! JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://mock.invalid")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
