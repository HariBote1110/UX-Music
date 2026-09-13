import SwiftUI

@main
struct UXMusicWatchApp: App {
    @StateObject private var library = WatchLocalLibrary()
    @StateObject private var playlistLibrary = WatchPlaylistLibrary()
    @StateObject private var player: WatchAudioPlayerService
    @StateObject private var hapticPlayback: WatchHapticPlayback
    @StateObject private var connectivity: WatchConnectivityReceiver

    init() {
        #if DEBUG
        WatchMainThreadStallMonitor.start()
        WatchPerfBreadcrumb.mark("app.init.begin")
        #endif
        let library = WatchLocalLibrary()
        _library = StateObject(wrappedValue: library)
        let playlistLibrary = WatchPlaylistLibrary()
        _playlistLibrary = StateObject(wrappedValue: playlistLibrary)
        let playerService = WatchAudioPlayerService(library: library)
        _player = StateObject(wrappedValue: playerService)
        let hapticService = WatchHapticPlayback(player: playerService, library: library)
        _hapticPlayback = StateObject(wrappedValue: hapticService)
        let connectivity = WatchConnectivityReceiver(
            library: library,
            playlistLibrary: playlistLibrary,
            hapticPlayback: hapticService
        )
        _connectivity = StateObject(wrappedValue: connectivity)
        // Activated here (app init) rather than a view's onAppear: WatchConnectivity can invoke
        // `didReceive` in the background before any view ever appears (e.g. the Watch app was
        // launched by the system just to handle the incoming transfer), so the delegate must be
        // registered as early as possible in the process's lifetime.
        #if DEBUG
        WatchPerfBreadcrumb.mark("app.init.connectivity.activate.begin")
        #endif
        connectivity.activate()
        #if DEBUG
        WatchPerfBreadcrumb.mark("app.init.connectivity.activate.end")
        #endif
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
        // Restore only after both indexes have loaded, so an empty in-memory library cannot discard
        // the saved queue during a cold launch.
        Task { @MainActor in
            #if DEBUG
            WatchPerfBreadcrumb.mark("restoreResumeState.waitForLibraries.begin")
            #endif
            await library.reloadAndWait()
            await playlistLibrary.reloadAndWait()
            #if DEBUG
            WatchPerfBreadcrumb.mark("restoreResumeState.waitForLibraries.end")
            #endif
            await playerService.restoreResumeState()
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(library)
                .environmentObject(playlistLibrary)
                .environmentObject(player)
                .environmentObject(player.progress)
                .environmentObject(hapticPlayback)
                .environmentObject(connectivity)
        }
    }
}
