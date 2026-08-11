import SwiftUI

/// Entry point for the tvOS app. Phase 1-1 scope: a placeholder shell only —
/// discovery/pairing/browsing UI land in later phases (see
/// `markdown/appletv-servermode-plan.md`, Phase 1-2 onward).
@main
struct UXMusicTVApp: App {
    var body: some Scene {
        WindowGroup {
            TVPlaceholderView()
        }
    }
}
