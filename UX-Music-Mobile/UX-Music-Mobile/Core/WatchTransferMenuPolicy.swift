import Foundation

/// Pure decision logic for where the "Apple Watch に転送" menu item is offered. Kept dependency-free
/// (no `WCSession`, no `AppModel`) so it is unit-testable; the SwiftUI wiring lives in
/// `WatchTransferMenuItems.swift`.
enum WatchTransferMenuPolicy {
    /// The menu should only appear at all when WatchConnectivity is supported on this device and a
    /// Watch is actually paired — offering a transfer action with nowhere to send it is confusing.
    static func canShowMenu(isWatchConnectivitySupported: Bool, isPaired: Bool) -> Bool {
        isWatchConnectivitySupported && isPaired
    }

    /// Selects the subset of `songs` eligible for a bulk (album/playlist) transfer: only songs
    /// already downloaded locally can be sent, matching the existing single-song transfer policy
    /// (`WatchTransferBridge.send`). Preserves the original ordering.
    static func songsEligibleForBulkTransfer(_ songs: [Song], downloadedIds: Set<String>) -> [Song] {
        songs.filter { downloadedIds.contains($0.id) }
    }
}
