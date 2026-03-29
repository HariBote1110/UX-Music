import SwiftUI
import WatchConnectivity

@main
struct UX_Music_WearApp: App {

    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var watchBridge = WatchBridge()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(libraryStore)
                .environmentObject(watchBridge)
                .onAppear {
                    watchBridge.activate()
                }
        }
    }
}
