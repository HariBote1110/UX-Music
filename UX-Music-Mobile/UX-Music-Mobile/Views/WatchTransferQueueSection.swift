import SwiftUI

/// The "APPLE WATCH" section of `SettingsScreen`: connection/pairing status plus the transfer queue.
///
/// Deliberately its own `@ObservedObject`-backed view rather than reading
/// `model.watchTransferBridge.…` straight from `SettingsScreen`'s body. `AppModel` is `@Observable`
/// (Observation framework) and `WatchTransferBridge` is a legacy `ObservableObject` with `@Published`
/// properties — an `@Observable` view does **not** subscribe to a nested `ObservableObject`'s
/// `objectWillChange`, so mutating `queue`/`activationStatus`/etc. on the bridge never invalidated
/// `SettingsScreen`'s body. In practice this showed up as transfer progress only refreshing when the
/// tab was switched (which recreates the view). Wrapping the bridge in `@ObservedObject` here
/// restores live updates. See `progress/watch-transfer-ui-observation.md` for the full writeup —
/// any other view that renders this bridge's `@Published` state (not just calls a method on it) needs
/// the same treatment.
struct WatchTransferQueueSection: View {
    @ObservedObject var bridge: WatchTransferBridge

    var body: some View {
        Section {
            HStack {
                Text("Connection Status")
                Spacer()
                Text(Self.activationStatusText(bridge.activationStatus))
                    .foregroundStyle(Self.activationStatusColor(bridge.activationStatus))
            }
            HStack {
                Text("Pairing Status")
                Spacer()
                Text(bridge.isPaired ? "Paired" : "Not Paired")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Watch App")
                Spacer()
                Text(bridge.isWatchAppInstalled ? "Installed" : "Not Installed")
                    .foregroundStyle(.secondary)
            }
            if bridge.queue.isEmpty {
                Text("No transferred songs yet. Long-press a song in your local library and choose \u{201C}Transfer to Apple Watch\u{201D}.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let summary = WatchTransferQueueSummary.aggregate(items: bridge.queue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: String(localized: "Completed %lld of %lld"), summary.completedCount, summary.totalCount))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if summary.isActive {
                        ProgressView(value: summary.meanFraction)
                    }
                }
                ForEach(bridge.queue) { item in
                    HStack {
                        Text(item.title)
                            .lineLimit(1)
                        Spacer()
                        Text(Self.transferStatusText(item.phase))
                            .font(.footnote)
                            .foregroundStyle(Self.transferStatusColor(item.phase))
                    }
                }
            }
        } header: {
            Text("APPLE WATCH")
        } footer: {
            // User report: transfers stall once the Watch screen turns off and watchOS returns to
            // the clock face — WCSession delivery only reliably flows while the Watch app is
            // frontmost. Shown only while something is actually in flight (see
            // `WatchTransferHintPolicy`), not for `.waiting`/`.downloading` items where nothing has
            // started sending yet.
            if WatchTransferHintPolicy.shouldShowFrontmostHint(items: bridge.queue) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep the Watch app open on your wrist while transferring — for long batches, extend Settings > General > Return to Clock for this app to Custom (1 Hour).")
                    Text("Charging the Watch and a fast Wi-Fi connection also speed up large transfers.")
                }
                .font(.footnote)
            }
        }
    }

    static func activationStatusText(_ status: WatchSessionActivationStatus) -> String {
        switch status {
        case .notActivated: return String(localized: "Not Connected")
        case .activating: return String(localized: "Connecting…")
        case .activated: return String(localized: "Connected")
        case .failed(let message):
            return String(format: String(localized: "Connection failed: %@"), message)
        }
    }

    static func activationStatusColor(_ status: WatchSessionActivationStatus) -> Color {
        switch status {
        case .activated: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    static func transferStatusText(_ phase: WatchTransferQueueItem.Phase) -> String {
        switch phase {
        case .downloading: return String(localized: "Downloading…")
        case .waiting: return String(localized: "Waiting")
        case .preparing: return String(localized: "Converting…")
        case .sending(let fraction):
            return String(format: String(localized: "Sending… %d%%"), Int((fraction * 100).rounded()))
        case .sent: return String(localized: "Sent")
        case .failed(let message):
            return String(format: String(localized: "Failed: %@"), message)
        }
    }

    static func transferStatusColor(_ phase: WatchTransferQueueItem.Phase) -> Color {
        switch phase {
        case .sent: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}
