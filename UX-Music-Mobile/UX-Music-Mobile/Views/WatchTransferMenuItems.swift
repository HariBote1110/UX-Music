import SwiftUI
import WatchConnectivity

/// Shared "Apple Watch に転送" context-menu button for a single song. Usable from any screen that
/// lists songs (Songs tab, album/playlist detail, Now Playing queue/favourites) so the action is not
/// limited to one screen. Renders nothing when WatchConnectivity is unsupported or no Watch is
/// paired. Always enabled: `WatchTransferBridge.send` downloads the song first (shown as
/// `.downloading` in the transfer queue) if it is not local yet, so this no longer needs to disable
/// itself for undownloaded songs.
struct WatchTransferSongMenuItem: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        if WatchTransferMenuPolicy.canShowMenu(
            isWatchConnectivitySupported: WCSession.isSupported(),
            isPaired: model.watchTransferBridge.isPaired
        ) {
            Button {
                model.watchTransferBridge.send(song)
            } label: {
                Label("Apple Watch に転送", systemImage: "applewatch")
            }
        }
    }
}

/// Bulk "Apple Watch に転送" context-menu button for an album/playlist: queues every song in `songs`
/// for transfer, downloading any that are not local yet (see `WatchTransferSongMenuItem`). Disabled
/// (not hidden) only when `songs` itself is empty, so the menu still communicates the action exists.
struct WatchTransferBulkMenuItem: View {
    @Environment(AppModel.self) private var model
    let title: String
    let songs: [Song]

    var body: some View {
        if WatchTransferMenuPolicy.canShowMenu(
            isWatchConnectivitySupported: WCSession.isSupported(),
            isPaired: model.watchTransferBridge.isPaired
        ) {
            let eligible = WatchTransferMenuPolicy.songsEligibleForBulkTransfer(
                songs,
                downloadedIds: Set(model.downloadManager.downloadedSongs.keys)
            )
            Button {
                for song in eligible {
                    model.watchTransferBridge.send(song)
                }
            } label: {
                Label(title, systemImage: "applewatch")
            }
            .disabled(eligible.isEmpty)
        }
    }
}
