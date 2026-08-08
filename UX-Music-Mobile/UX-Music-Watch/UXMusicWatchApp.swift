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
