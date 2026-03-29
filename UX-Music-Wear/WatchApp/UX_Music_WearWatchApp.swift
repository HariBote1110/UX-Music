import SwiftUI

@main
struct UX_Music_WearWatchApp: App {

    @StateObject private var player = AudioPlayerService()
    @StateObject private var library = LocalLibrary()
    @StateObject private var connectivityHandler = WatchConnectivityHandler()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(connectivityHandler)
                .onAppear {
                    connectivityHandler.activate()
                    connectivityHandler.onFileReceived = { [weak library] song, fileURL in
                        library?.addSong(song, fileURL: fileURL)
                    }
                }
        }
    }
}
