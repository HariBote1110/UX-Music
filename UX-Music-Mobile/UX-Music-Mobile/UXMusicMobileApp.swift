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
}
