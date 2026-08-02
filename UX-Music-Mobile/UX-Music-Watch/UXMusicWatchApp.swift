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
        _connectivity = StateObject(wrappedValue: WatchConnectivityReceiver(library: library))
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(library)
                .environmentObject(player)
                .environmentObject(connectivity)
                .onAppear {
                    connectivity.activate()
                }
        }
    }
}
