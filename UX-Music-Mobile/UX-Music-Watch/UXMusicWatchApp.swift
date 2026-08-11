import SwiftUI

@main
struct UXMusicWatchApp: App {
    @StateObject private var library = WatchLocalLibrary()
    @StateObject private var player: WatchAudioPlayerService
    @StateObject private var connectivity: WatchConnectivityReceiver

    init() {
        let library = WatchLocalLibrary()
        _library = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: WatchAudioPlayerService(library: library))
        let connectivity = WatchConnectivityReceiver(library: library)
        _connectivity = StateObject(wrappedValue: connectivity)
        // Activated here (app init) rather than a view's onAppear: WatchConnectivity can invoke
        // `didReceive` in the background before any view ever appears (e.g. the Watch app was
        // launched by the system just to handle the incoming transfer), so the delegate must be
        // registered as early as possible in the process's lifetime.
        connectivity.activate()
        // User report: "画面OFFになったあと勝手に文字盤に戻っちゃって転送が止まる" — once the
        // screen turns off, watchOS returns to the clock face after its "on screen wake show last
        // app" grace period, and WCSession file delivery stalls until this app is frontmost again.
        //
        // This used to call `WKExtension.shared().isFrontmostTimeoutExtended = true` to ask for a
        // longer grace period, but that call itself crashes at launch: this is a SwiftUI-lifecycle
        // watchOS app, which has no `WKExtension` instance at all, so `WKExtension.shared()` aborts
        // immediately (user-confirmed device console line). The property is also deprecated/no-op
        // from watchOS 7 onwards regardless (`WK_DEPRECATED_WATCHOS(4.0, 7.0, "No longer
        // supported")`), and `WKApplication.shared().isFrontmostTimeoutExtended` — the
        // SwiftUI-lifecycle equivalent — carries the same "no longer supported" deprecation, so it
        // is not a viable replacement either. This mitigation is fully withdrawn; the durable fix is
        // a direct background `URLSession` download on the Watch (see
        // `watch_transfer_research/notes/watch-direct-download-plan.md`), which survives app
        // suspension by design instead of depending on frontmost state at all.
        // Restore the last song/position/queue/mode (without autoplaying) so the app reopens where
        // the user left off, matching classic Walkman "resume" behaviour.
        player.restoreResumeState()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(player.progress)
                .environmentObject(connectivity)
        }
    }
}
