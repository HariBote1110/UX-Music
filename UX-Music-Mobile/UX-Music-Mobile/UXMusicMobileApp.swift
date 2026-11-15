import AVFoundation
import SwiftUI
import UIKit

@main
struct UXMusicMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var debugShowAlbumDetail = ProcessInfo.processInfo.environment["UXM_DEBUG_ALBUM_DETAIL"] == "1"
    #endif

    var body: some Scene {
        WindowGroup {
            HomeRootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.beginReceivingRemoteControlEvents()
                    installDebugYouTubeAutoplayHookIfRequested()
                    installDebugNowPlayingStaticHookIfRequested()
                    installDebugLyricsAutoOpenHookIfRequested()
                    installDebugSidecarHostHookIfRequested()
                    #if DEBUG
                    installDebugPerfScenarioHookIfRequested()
                    #endif
                }
                #if DEBUG
                // DEBUG-only (`UXM_DEBUG_ALBUM_DETAIL=1`): shows `AlbumDetailView` with fake songs
                // for before/after layout comparisons.
                .fullScreenCover(isPresented: $debugShowAlbumDetail) {
                    NavigationStack {
                        AlbumDetailView(album: Album.fromSongs((1...40).map {
                            Song(id: "dbg-\($0)", path: "/nonexistent/\($0).m4a", title: "Track \($0)", artist: "Debug Artist", album: "Debug Album", duration: 180, trackNumber: $0)
                        })[0])
                    }
                    .environment(model)
                    .preferredColorScheme(.dark)
                }
                #endif
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

    #if DEBUG
    /// DEBUG-only: `UXM_DEBUG_PERF_SCENARIO` selects a scripted scene for on-device energy
    /// measurement (`mobile_perf_research/tools/device_energy.sh`). Supported values:
    /// `idle_control_visited` (needs the stub server via `UXM_DEBUG_SIDECAR_HOST`/`PORT`),
    /// `playing_control_visited` (tone + Control tab visited), `playing_control_selected` (tone, stays on
    /// the Control tab; for background playback), `local_playing`,
    /// `local_paused`, `nowplaying_open`. `youtube_hidden` is handled by the
    /// existing `UXM_DEBUG_YT_VIDEO` + `UXM_DEBUG_YT_SERVICE=1` hook, so nothing happens here for it.
    private func installDebugPerfScenarioHookIfRequested() {
        guard let scenario = ProcessInfo.processInfo.environment["UXM_DEBUG_PERF_SCENARIO"], !scenario.isEmpty else {
            return
        }
        NSLog("[UXM_DEBUG_PERF] scenario=%@", scenario)
        // Keep the display on while the app is in the foreground so a locked screen does not
        // silently turn a foreground scenario into a background one mid-measurement.
        UIApplication.shared.isIdleTimerDisabled = true
        let model = model
        // `playing_control_visited` = the background-playback case for the Control-tab poll: play the
        // tone *and* visit the Control tab, so the app keeps running after it is backgrounded.
        // `playing_control_selected` additionally stays on the Control tab (the baseline polls until the
        // app is suspended, which never happens while audio plays in the background).
        let staysOnControl = scenario == "playing_control_selected"
        let visitsControl = ["idle_control_visited", "playing_control_visited"].contains(scenario) || staysOnControl
        let playsTone = ["local_playing", "local_paused", "nowplaying_open", "playing_control_visited", "playing_control_selected"].contains(scenario)
        guard visitsControl || playsTone else { return }
        if visitsControl {
            Task { @MainActor in
                // Let the sidecar hook (registered just before this one) finish pointing serverConfig at the stub.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                NotificationCenter.default.post(name: .uxmDebugSelectTab, object: "control")
                NSLog("[UXM_DEBUG_PERF] selected Control tab")
                if staysOnControl { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                NotificationCenter.default.post(name: .uxmDebugSelectTab, object: "library")
                NSLog("[UXM_DEBUG_PERF] switched back to Library tab; idling")
            }
        }
        if playsTone {
            Task { @MainActor in
                guard let url = await Self.debugToneFileURL() else {
                    NSLog("[UXM_DEBUG_PERF] tone file generation failed")
                    return
                }
                let song = Song(id: "debug-perf-tone", path: url.path, title: "Perf Tone", artist: "Debug Artist", album: "Debug Album", duration: 600)
                await model.player.play(song, newQueue: [song])
                NSLog("[UXM_DEBUG_PERF] play returned isPlaying=%d", model.player.isPlaying ? 1 : 0)
                if scenario == "nowplaying_open" {
                    model.isNowPlayingSheetPresented = true
                }
                if scenario == "local_paused" {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if model.player.isPlaying { model.player.togglePlayPause() }
                    NSLog("[UXM_DEBUG_PERF] paused isPlaying=%d", model.player.isPlaying ? 1 : 0)
                }
            }
        }
    }

    /// Writes (once) a deterministic quiet 440 Hz stereo sine, 10 minutes at 44.1 kHz, 16-bit PCM,
    /// into the caches directory and returns its URL.
    private static func debugToneFileURL() async -> URL? {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("uxm-perf-tone-600s.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return await Task.detached(priority: .utility) { () -> URL? in
            let sampleRate = 44_100.0
            let seconds = 600
            let partial = url.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: partial)
            do {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                let file = try AVAudioFile(forWriting: partial, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let frames = AVAudioFrameCount(sampleRate)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
                buffer.frameLength = frames
                let amplitude: Float = 0.05
                var phase = 0.0
                let step = 2.0 * Double.pi * 440.0 / sampleRate
                for _ in 0..<seconds {
                    for channel in 0..<2 {
                        guard let data = buffer.floatChannelData?[channel] else { return nil }
                        var p = phase
                        for i in 0..<Int(frames) {
                            data[i] = amplitude * Float(sin(p))
                            p += step
                        }
                    }
                    phase += step * Double(frames)
                    phase = phase.truncatingRemainder(dividingBy: 2.0 * Double.pi)
                    try file.write(from: buffer)
                }
                try FileManager.default.moveItem(at: partial, to: url)
                return url
            } catch {
                NSLog("[UXM_DEBUG_PERF] tone generation error=%@", String(describing: error))
                return nil
            }
        }.value
    }
    #endif

    /// DEBUG-only: `UXM_DEBUG_NP_LOCAL=1` shows Now Playing with a fixed fake local song (no audio,
    /// no network) so rendering changes can be compared pixel-wise before/after.
    private func installDebugNowPlayingStaticHookIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["UXM_DEBUG_NP_LOCAL"] == "1" else { return }
        let song = Song(id: "debug-np-local", path: "/nonexistent/debug.m4a", title: "Debug Song", artist: "Debug Artist", album: "Debug Album", duration: 200)
        model.player.configureForPreview(song: song, isPlaying: false, positionSeconds: 60, durationSeconds: 200)
        model.isNowPlayingSheetPresented = true
        #endif
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

#if DEBUG
extension Notification.Name {
    /// DEBUG-only: posted with `object` = "library" / "control" to drive `HomeRootView`'s tab selection.
    static let uxmDebugSelectTab = Notification.Name("UXMDebugSelectTab")
}
#endif
