import SwiftUI

/// Entry point for the tvOS app. Phase 1-2 scope: mDNS discovery + pairing
/// (`TVRootView`). Browsing/playback UI land in later phases (see
/// `markdown/appletv-servermode-plan.md`, Phase 1-3 onward).
@main
struct UXMusicTVApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // DEBUG-only preview harness (`progress/tvos-design.md`): launching with
            // `UXTV_PREVIEW=nowplaying|browse|albumdetail` (e.g. via
            // `SIMCTL_CHILD_UXTV_PREVIEW=nowplaying xcrun simctl launch …`) renders a screen with
            // rich stub data, no pairing/network required, so the cinematic design can be
            // screenshotted directly in the simulator.
            switch ProcessInfo.processInfo.environment["UXTV_PREVIEW"] {
            case "nowplaying":
                TVNowPlayingPreviewHarness()
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
#endif
