import SwiftUI

/// Playlists list screen, reached from a `NavigationLink` at the top of `WatchSongListView`
/// alongside "Songs"/"Albums" — see that view's doc comment. Empty state mirrors the Library page's
/// own "no songs yet" message (transfers are always iPhone-initiated).
struct WatchPlaylistListView: View {
    @EnvironmentObject private var playlistLibrary: WatchPlaylistLibrary
    @EnvironmentObject private var library: WatchLocalLibrary
    @Binding var selectedPage: WatchPage

    var body: some View {
        Group {
            if playlistLibrary.playlists.isEmpty {
                Text("No playlists\nTransfer from the iPhone app")
                    .multilineTextAlignment(.center)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(playlistLibrary.playlists) { playlist in
                    NavigationLink {
                        WatchPlaylistDetailView(playlist: playlist, selectedPage: $selectedPage)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.displayName)
                                .font(.body)
                                .lineLimit(1)
                            let count = WatchPlaylistQueueBuilder.resolvedSongs(for: playlist, librarySongs: library.songs).count
                            Text(String(format: String(localized: "%d songs"), count))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
    }
}

/// One playlist's resolved song list (missing songs silently dropped — see
/// `WatchPlaylistQueueBuilder.resolvedSongs`). Tapping a song starts the *whole playlist* playing as
/// the queue, positioned at that song — the same "tap a track, play the containing collection"
/// pattern `WatchAlbumDetailView` uses for albums (`WatchSongListView.swift`).
private struct WatchPlaylistDetailView: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    @EnvironmentObject private var player: WatchAudioPlayerService
    let playlist: WatchPlaylistMeta
    @Binding var selectedPage: WatchPage

    private var resolvedSongs: [WatchTransferMeta] {
        WatchPlaylistQueueBuilder.resolvedSongs(for: playlist, librarySongs: library.songs)
    }

    var body: some View {
        Group {
            if resolvedSongs.isEmpty {
                Text("None of this playlist's songs have been transferred yet")
                    .multilineTextAlignment(.center)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(resolvedSongs) { meta in
                    WatchSongRow(meta: meta, queue: resolvedSongs) { selectedPage = .nowPlaying }
                }
            }
        }
        .navigationTitle(playlist.displayName)
    }
}

#Preview {
    let library = WatchLocalLibrary()
    let playlistLibrary = WatchPlaylistLibrary()
    NavigationStack {
        WatchPlaylistListView(selectedPage: .constant(.library))
    }
    .environmentObject(library)
    .environmentObject(playlistLibrary)
    .environmentObject(WatchAudioPlayerService(library: library))
}
