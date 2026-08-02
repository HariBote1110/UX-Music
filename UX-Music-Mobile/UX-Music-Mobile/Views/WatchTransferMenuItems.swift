import SwiftUI
import WatchConnectivity

/// Shared "Apple Watch に転送" context-menu button for a single song. Usable from any screen that
/// lists songs (Songs tab, album/playlist detail, Now Playing queue/favourites) so the action is not
/// limited to one screen. Renders nothing when WatchConnectivity is unsupported or no Watch is
/// paired; otherwise the button is disabled for songs that are not downloaded locally, matching the
/// existing `WatchTransferBridge.send` policy.
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
            .disabled(!model.isSongDownloaded(songId: song.id))
        }
    }
}

/// Bulk "Apple Watch に転送" context-menu button for an album/playlist: queues every downloaded song
/// in `songs` for transfer. Disabled (not hidden) when none of the songs are downloaded yet, so the
/// menu still communicates the action exists.
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
