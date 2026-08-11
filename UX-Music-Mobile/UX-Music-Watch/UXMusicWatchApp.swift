import SwiftUI
import WatchKit

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
        // app" grace period (2 minutes by default), and WCSession file delivery stalls until this
        // app is frontmost again. `isFrontmostTimeoutExtended` asks for the longer 8-minute grace
        // instead, which covers most single-song/small-album transfers.
        //
        // Caveat found while implementing this: WatchKit's header for this property marks it
        // `WK_DEPRECATED_WATCHOS(4.0, 7.0, "No longer supported")` — Apple stopped honouring it
        // from watchOS 7 onwards, and this project's `WATCHOS_DEPLOYMENT_TARGET` is 10.0. There is
        // no direct replacement for arbitrary background work (`WKExtendedRuntimeSession` is scoped
        // to workout/mindfulness/alarm-style sessions, not general connectivity), so this call is
        // kept as a harmless best-effort — it may be a no-op on current watchOS. The durable fix is
        // a direct background `URLSession` download on the Watch (see
        // `watch_transfer_research/notes/watch-direct-download-plan.md`), which survives app
        // suspension by design instead of depending on frontmost state at all.
        WKExtension.shared().isFrontmostTimeoutExtended = true
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
