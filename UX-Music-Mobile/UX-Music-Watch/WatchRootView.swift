import SwiftUI

/// The two pages of the Watch app, swiped between horizontally like watchOS's own Music app
/// (Now Playing is always reachable, regardless of what is selected in the library).
enum WatchPage: Hashable {
    case library
    case nowPlaying
}

/// Root screen for the UX Music Watch app: a horizontally-paged `TabView` with the song library
/// on one page and Now Playing on the other, so playback controls stay reachable at all times —
/// tapping a song switches to Now Playing, but swiping back to Library never loses the ability to
/// swipe forward again.
struct WatchRootView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityReceiver
    @EnvironmentObject private var library: WatchLocalLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedPage: WatchPage = .library

    var body: some View {
        ZStack {
            TabView(selection: $selectedPage) {
                WatchSongListView(selectedPage: $selectedPage)
                    .tag(WatchPage.library)
                WatchNowPlayingView()
                    .tag(WatchPage.nowPlaying)
            }
            .tabViewStyle(.page)

            if connectivity.isReceiving {
                VStack(spacing: 4) {
                    ProgressView()
                    Text("Receiving \(connectivity.receivingTitle)…")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Belt-and-braces: the library already updates live via `@Published songs` as files
            // arrive, but re-reading from disk on foreground guards against any transfer that
            // completed while the app was suspended and missed a `@Published` update.
            if newPhase == .active {
                library.reload()
            }
        }
    }
}

#Preview {
    let library = WatchLocalLibrary()
    WatchRootView()
        .environmentObject(library)
        .environmentObject(WatchAudioPlayerService(library: library))
        .environmentObject(WatchConnectivityReceiver(library: library))
}
