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

    /// All songs eligible for a bulk (album/playlist) transfer, in the original order.
    ///
    /// Previously filtered to only already-downloaded songs, matching the old single-song
    /// `WatchTransferBridge.send` policy. That filter is gone now that `send` downloads an
    /// undownloaded song before transferring it (see `WatchTransferBridge.downloadThenQueue`) — a
    /// bulk transfer used to silently drop any track that had not been downloaded yet, so e.g. a
    /// two-track album with one downloaded track appeared to fully transfer while actually sending
    /// only one song. `downloadedIds` is kept as a parameter for call-site source compatibility but
    /// is no longer consulted.
    static func songsEligibleForBulkTransfer(_ songs: [Song], downloadedIds: Set<String>) -> [Song] {
        songs
    }
}
