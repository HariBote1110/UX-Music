import SwiftUI
import WatchConnectivity

/// Shared "Apple Watch に転送" context-menu button for a single song. Usable from any screen that
/// lists songs (Songs tab, album/playlist detail, Now Playing queue/favourites) so the action is not
/// limited to one screen. Renders nothing when WatchConnectivity is unsupported or no Watch is
/// paired. Always enabled: `WatchTransferBridge.send` downloads the song first (shown as
/// `.downloading` in the transfer queue) if it is not local yet, so this no longer needs to disable
/// itself for undownloaded songs.
///
/// Only fetches `model.watchTransferBridge` here and hands it straight to `WatchTransferSongMenuItemBody`,
/// which does the actual `isPaired` check as an `@ObservedObject` observer — `AppModel` is `@Observable`
/// and does not forward a nested `ObservableObject`'s `@Published` changes, so reading
/// `model.watchTransferBridge.isPaired` directly here would go stale the same way the Settings queue
/// used to (see `progress/watch-transfer-ui-observation.md`).
struct WatchTransferSongMenuItem: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        WatchTransferSongMenuItemBody(bridge: model.watchTransferBridge, song: song)
    }
}

private struct WatchTransferSongMenuItemBody: View {
    @ObservedObject var bridge: WatchTransferBridge
    let song: Song

    var body: some View {
        if WatchTransferMenuPolicy.canShowMenu(
            isWatchConnectivitySupported: WCSession.isSupported(),
            isPaired: bridge.isPaired
        ), WatchTransferMenuPolicy.isEligibleForTransfer(song) {
            Button {
                bridge.send(song)
            } label: {
                Label("Transfer to Apple Watch", systemImage: "applewatch")
            }
        }
    }
}

/// Bulk "Apple Watch に転送" context-menu button for an album/playlist: queues every song in `songs`
/// for transfer, downloading any that are not local yet (see `WatchTransferSongMenuItem`). Disabled
/// (not hidden) only when `songs` itself is empty, so the menu still communicates the action exists.
///
/// `title` is `LocalizedStringKey`, not `String` — every call site passes a string literal
/// ("Transfer Album to Apple Watch" etc.) that *is* translated in `Localizable.xcstrings`, but with
/// the parameter typed as plain `String` the compiler resolved `Label(_:systemImage:)` to the
/// `StringProtocol` overload, which renders verbatim (no locale lookup) — so the button always showed
/// raw English even on a Japanese device. `LocalizedStringKey` restores the localized overload.
struct WatchTransferBulkMenuItem: View {
    @Environment(AppModel.self) private var model
    let title: LocalizedStringKey
    let songs: [Song]

    var body: some View {
        WatchTransferBulkMenuItemBody(
            bridge: model.watchTransferBridge,
            title: title,
            songs: songs,
            downloadedIds: Set(model.downloadManager.downloadedSongs.keys)
        )
    }
}

private struct WatchTransferBulkMenuItemBody: View {
    @ObservedObject var bridge: WatchTransferBridge
    let title: LocalizedStringKey
    let songs: [Song]
    let downloadedIds: Set<String>

    var body: some View {
        if WatchTransferMenuPolicy.canShowMenu(
            isWatchConnectivitySupported: WCSession.isSupported(),
            isPaired: bridge.isPaired
        ) {
            let eligible = WatchTransferMenuPolicy.songsEligibleForBulkTransfer(
                songs,
                downloadedIds: downloadedIds
            )
            Button {
                for song in eligible {
                    bridge.send(song)
                }
            } label: {
                Label(title, systemImage: "applewatch")
            }
            .disabled(eligible.isEmpty)
        }
    }
}
