import SwiftUI

/// Root screen for the UX Music Watch app: shows the synced song library received from the
/// paired iPhone, with a brief overlay while a transfer is in progress.
struct WatchRootView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityReceiver

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
    }
}

#Preview {
    WatchRootView()
        .environmentObject(WatchLocalLibrary())
        .environmentObject(WatchAudioPlayerService(library: WatchLocalLibrary()))
        .environmentObject(WatchConnectivityReceiver(library: WatchLocalLibrary()))
}
