import SwiftUI
import UIKit

@main
struct UXMusicMobileApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeRootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.beginReceivingRemoteControlEvents()
                    installDebugYouTubeAutoplayHookIfRequested()
                    installDebugLyricsAutoOpenHookIfRequested()
                }
                .onOpenURL { url in
                    Task { _ = await model.applyPairingURL(url) }
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
        let previousHandler = host.onEvent
        host.onEvent = { event in
            NSLog("[UXM_DEBUG_YT] bridge event=%@", String(describing: event))
            previousHandler?(event)
        }
        Task {
            do {
                try await host.load(videoID: videoID)
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
}
