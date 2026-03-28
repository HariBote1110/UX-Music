import SwiftUI

struct SyncView: View {
    @EnvironmentObject private var watchBridge: WatchBridge

    var body: some View {
        NavigationStack {
            Group {
                if watchBridge.queue.isEmpty && watchBridge.completed.isEmpty {
                    ContentUnavailableView(
                        "No Transfers",
                        systemImage: "tray",
                        description: Text("Select songs in Library and tap the Watch icon to queue them.")
                    )
                } else {
                    transferList
                }
            }
            .navigationTitle("Watch Sync")
            .toolbar {
                if !watchBridge.queue.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Cancel All") { watchBridge.cancelAll() }
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var transferList: some View {
        List {
            if !watchBridge.queue.isEmpty {
                Section("Queued / In Progress") {
                    ForEach(watchBridge.queue) { item in
                        TransferRow(item: item)
                    }
                }
            }
            if !watchBridge.completed.isEmpty {
                Section("Completed") {
                    ForEach(watchBridge.completed.suffix(20).reversed()) { item in
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(item.song.displayTitle)
                        }
                    }
                }
            }
        }
    }
}

struct TransferRow: View {
    let item: TransferItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.song.displayTitle)
                .font(.body)
            switch item.phase {
            case .waiting:
                Text("Waiting…").font(.caption).foregroundStyle(.secondary)
            case .downloading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            case .sending:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Sending to Watch…").font(.caption).foregroundStyle(.secondary)
                }
            case .failed(let err):
                Text("Failed: \(err)").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}
