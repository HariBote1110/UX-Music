import SwiftUI

/// Entry point for the tvOS app. Phase 1-2 scope: mDNS discovery + pairing
/// (`TVRootView`). Browsing/playback UI land in later phases (see
/// `markdown/appletv-servermode-plan.md`, Phase 1-3 onward).
@main
struct UXMusicTVApp: App {
    var body: some Scene {
        WindowGroup {
            TVRootView()
        }
    }
}
