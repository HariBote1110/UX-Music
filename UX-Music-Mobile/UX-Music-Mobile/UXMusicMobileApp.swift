import SwiftUI
import UIKit

@main
struct UXMusicMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeRootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.beginReceivingRemoteControlEvents()
                    installDebugYouTubeAutoplayHookIfRequested()
                    installDebugLyricsAutoOpenHookIfRequested()
                    installDebugSidecarHostHookIfRequested()
                }
                .onOpenURL { url in
                    Task { _ = await model.applyPairingURL(url) }
                }
                // The desktop's "sidecar" fullscreen push (see `SidecarScreen`) only makes sense
                // while the app is actually on screen — polling in the background would burn
                // battery/network for a display the user cannot see.
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    if newPhase == .active {
                        model.startSidecarPolling()
                    } else {
                        model.stopSidecarPolling()
                    }
                }
        }
    }

    /// Hidden debug hook for reproducing/diagnosing YouTube official-playback embed errors on a
    /// real device or simulator without having to drive the full song-picking UI. When the
    /// `UXM_DEBUG_YT_VIDEO` environment variable (e.g. set via `xcrun simctl launch --setenv
    /// UXM_DEBUG_YT_VIDEO <videoID> ...`) is present, immediately loads that video ID on the
    /// shared `YouTubePlaybackHost` and logs every IFrame Player API bridge event (ready/state/
    /// error) via `NSLog` so it can be observed with `xcrun simctl spawn <udid> log stream`. Left
    /// in place intentionally — harmless in normal launches since the environment variable is
    /// never set outside of manual debugging.
    private func installDebugYouTubeAutoplayHookIfRequested() {
        guard let videoID = ProcessInfo.processInfo.environment["UXM_DEBUG_YT_VIDEO"], !videoID.isEmpty else {
            return
        }
        NSLog("[UXM_DEBUG_YT] starting debug autoplay for videoID=%@", videoID)
        let host = model.player.youtubePlaybackHost
        let player = model.player
        let previousHandler = host.onEvent
        host.onEvent = { event in
            previousHandler?(event)
            NSLog("[UXM_DEBUG_YT] bridge event=%@ isPlaying=%d", String(describing: event), player.isPlaying ? 1 : 0)
        }
        for name in [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification,
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    NSLog("[UXM_DEBUG_YT] lifecycle %@ isPlaying=%d", name.rawValue, player.isPlaying ? 1 : 0)
                }
            }
        }
        // `UXM_DEBUG_YT_SERVICE=1` plays a synthetic YouTube `Song` through `MusicPlayerService.play`
        // (with the desktop resolver stubbed out) instead of driving the host directly, so the
        // service-level behaviour — e.g. PiP entry and the unavailable-device fallback — can be
        // observed without a paired desktop.
        if ProcessInfo.processInfo.environment["UXM_DEBUG_YT_SERVICE"] == "1" {
            let watchURL = "https://www.youtube.com/watch?v=\(videoID)"
            let song = Song(id: "debug-yt-\(videoID)", path: watchURL, title: "Debug YouTube", sourceType: .youtube, sourceURL: watchURL)
            player.resolveYouTubeVideoID = { _ in videoID }
            // `UXM_DEBUG_YT_FULLSCREEN=1` additionally puts the video into native fullscreen a few
            // seconds into playback, so the automatic fullscreen-to-PiP hand-off on backgrounding can be
            // checked on a device without tapping the Now Playing button (progress/mobile-youtube-embed.md フェーズH).
            let enterFullscreen = ProcessInfo.processInfo.environment["UXM_DEBUG_YT_FULLSCREEN"] == "1"
            // `UXM_DEBUG_YT_OPEN_NOW_PLAYING=1` opens Now Playing once playback has started, so the
            // Now Playing PiP / fullscreen buttons can be tapped by hand on a device.
            let openNowPlaying = ProcessInfo.processInfo.environment["UXM_DEBUG_YT_OPEN_NOW_PLAYING"] == "1"
            Task {
                await player.play(song, newQueue: [song])
                NSLog("[UXM_DEBUG_YT] service play(_:newQueue:) returned")
                if openNowPlaying {
                    model.isNowPlayingSheetPresented = true
                    NSLog("[UXM_DEBUG_YT] opened Now Playing")
                }
                guard enterFullscreen else { return }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                NSLog("[UXM_DEBUG_YT] requesting fullscreen canUse=%d", player.canUseYouTubeFullscreen ? 1 : 0)
                player.enterYouTubeFullscreen()
            }
            return
        }
        Task {
            do {
                // `UXM_DEBUG_YT_LQ=1` forces the cellular low-quality page so the reported
                // `quality` bridge events can be checked without a real cellular connection.
                let lowQuality = ProcessInfo.processInfo.environment["UXM_DEBUG_YT_LQ"] == "1"
                try await host.load(videoID: videoID, lowQuality: lowQuality)
                NSLog("[UXM_DEBUG_YT] load(videoID:) returned without throwing")
            } catch {
                NSLog("[UXM_DEBUG_YT] load(videoID:) threw error=%@", String(describing: error))
            }
        }
    }

    /// Hidden debug hook for recording/inspecting the synced-lyrics screen motion without
    /// having to drive the tap-through library → play → Now Playing → lyrics UI by hand (tap
    /// injection is unreliable in this environment's simulator automation). When the
    /// `UXM_DEBUG_LYRICS_SONG` environment variable (a case-insensitive title/artist substring,
    /// e.g. set via `xcrun simctl launch --setenv UXM_DEBUG_LYRICS_SONG "GReeeeN" ...`) is
    /// present, loads the library, plays the first matching downloaded local song, and opens
    /// Now Playing with the lyrics screen already presented. Left in place intentionally —
    /// harmless in normal launches since the environment variable is never set outside of
    /// manual debugging.
    private func installDebugLyricsAutoOpenHookIfRequested() {
        guard let query = ProcessInfo.processInfo.environment["UXM_DEBUG_LYRICS_SONG"], !query.isEmpty else {
            return
        }
        NSLog("[UXM_DEBUG_LYRICS] searching library for query=%@", query)
        Task {
            await model.refreshLibrary()
            guard case .loaded(let songs) = model.libraryState else {
                NSLog("[UXM_DEBUG_LYRICS] library not loaded, state=%@", String(describing: model.libraryState))
                return
            }
            let needle = query.lowercased()
            guard let song = songs.first(where: { $0.id == query })
                ?? songs.first(where: {
                    $0.title.lowercased().contains(needle) || $0.artist.lowercased().contains(needle)
                }) else {
                NSLog("[UXM_DEBUG_LYRICS] no song matched query=%@ (library has %d songs)", query, songs.count)
                return
            }
            NSLog("[UXM_DEBUG_LYRICS] playing song id=%@ title=%@", song.id, song.title)
            await model.player.play(song, newQueue: songs)
            model.debugForceOpenLyrics = true
            model.isNowPlayingSheetPresented = true
        }
    }

    /// Hidden debug hook for reproducing the sidecar-screen CPU/RSS leak (see
    /// `progress/sidecar-poll-tick-cpu-leak.md`) without a real desktop paired. When the
    /// `UXM_DEBUG_SIDECAR_HOST` environment variable (e.g. `127.0.0.1`, paired with
    /// `UXM_DEBUG_SIDECAR_PORT`, set by exporting `SIMCTL_CHILD_UXM_DEBUG_SIDECAR_HOST=127.0.0.1`
    /// and `SIMCTL_CHILD_UXM_DEBUG_SIDECAR_PORT=8799` in the shell before `xcrun simctl launch` —
    /// `simctl` only forwards env vars prefixed `SIMCTL_CHILD_` to the launched process) is
    /// present, points `serverConfig` at that host/port with a dummy token so
    /// `startSidecarPolling()` (already running via the `scenePhase` handler above) drives
    /// `SidecarScreen`'s `fullScreenCover` against a local stub server
    /// (`scripts/sidecar_stub_server.py` answers `/v1/remote/state` with `sidecar.active=true`).
    /// Left in place intentionally — harmless in normal launches since the environment variable
    /// is never set outside of manual debugging.
    private func installDebugSidecarHostHookIfRequested() {
        guard let host = ProcessInfo.processInfo.environment["UXM_DEBUG_SIDECAR_HOST"], !host.isEmpty else {
            return
        }
        let port = ProcessInfo.processInfo.environment["UXM_DEBUG_SIDECAR_PORT"].flatMap(Int.init) ?? 8799
        NSLog("[UXM_DEBUG_SIDECAR] pointing serverConfig at %@:%d", host, port)
        model.serverConfig = ServerConfig(host: host, port: port, token: "debug-sidecar-token")
    }
}
