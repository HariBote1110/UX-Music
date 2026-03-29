import SwiftUI

struct TransferView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityHandler

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "applewatch.and.arrow.forward")
                .font(.system(size: 32))
                .foregroundStyle(.blue)

            Text("Watch Sync")
                .font(.headline)

            if connectivity.isReceiving {
                VStack(spacing: 4) {
                    ProgressView()
                    Text("Receiving \(connectivity.receivingTitle)…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            } else {
                Text("Send songs from the iPhone app to sync them here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .navigationTitle("Transfer")
    }
}
