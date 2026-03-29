import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var player: AudioPlayerService

    var body: some View {
        TabView {
            NowPlayingView()
            LibraryView()
            TransferView()
        }
        .tabViewStyle(.page)
    }
}
