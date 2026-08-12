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
            case "relay":
                TVRelayStreamPreviewHarness()
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
#endif
