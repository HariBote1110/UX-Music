import SwiftUI

/// Root screen for the UX Music Watch app: shows the synced song library received from the
/// paired iPhone, with a brief overlay while a transfer is in progress.
struct WatchRootView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityReceiver
    @EnvironmentObject private var library: WatchLocalLibrary
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            WatchSongListView()

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
    WatchRootView()
        .environmentObject(WatchLocalLibrary())
        .environmentObject(WatchAudioPlayerService(library: WatchLocalLibrary()))
        .environmentObject(WatchConnectivityReceiver(library: WatchLocalLibrary()))
}
