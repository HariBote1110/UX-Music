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
            default:
                TVRootView()
            }
            #else
            TVRootView()
            #endif
        }
    }
}
