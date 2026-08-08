import SwiftUI
import UIKit

/// Library page: a plain native `List` with two `NavigationLink` rows ("Songs"/"Albums") pushing
/// the flat song list and the album list respectively — the same drill-down pattern watchOS's own
/// Music app uses for its library, rather than a custom segmented-style toggle. Tapping a song row
/// starts playback and switches to the Now Playing page (see `WatchRootView`'s paged `TabView`).
/// Deletion is a long-press context menu rather than a row swipe: on watchOS the Library and Now
/// Playing/Queue pages are themselves swiped between horizontally (see `WatchRootView`), and a
/// right-swipe on a list row was being captured by the row's own `swipeActions` instead of the page
/// `TabView`, making it impossible to swipe from Library to Now Playing while a finger started on a
/// row. A long press has no such conflict.
struct WatchSongListView: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    @Binding var selectedPage: WatchPage

    private var albums: [WatchAlbumGroup] { WatchAlbumGrouping.albums(from: library.songs) }

    var body: some View {
        NavigationStack {
            Group {
                if library.songs.isEmpty {
                    Text("曲がありません\niPhone アプリから転送してください")
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    List {
                        NavigationLink {
                            songList(library.songs)
                                .navigationTitle("曲")
                        } label: {
                            Label("曲", systemImage: "music.note")
                        }
                        NavigationLink {
                            albumList
                        } label: {
                            Label("アルバム", systemImage: "square.stack")
                        }
                    }
                }
            }
            .navigationTitle("ライブラリ")
        }
    }

    private func songList(_ songs: [WatchTransferMeta]) -> some View {
        List(songs) { meta in
            WatchSongRow(meta: meta, queue: songs) { selectedPage = .nowPlaying }
        }
    }

    private var albumList: some View {
        List(albums) { album in
            NavigationLink {
                WatchAlbumDetailView(album: album, selectedPage: $selectedPage)
            } label: {
                HStack {
                    WatchArtworkThumbnail(meta: album.artworkSong)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.album)
                            .font(.body)
                            .lineLimit(1)
                        Text("\(album.songs.count)曲")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("アルバム")
    }
}

/// One song's worth of an album's track list, shown by `WatchAlbumDetailView`. Tapping a track
/// starts the whole album playing as the queue (in track order), positioned at that track — not
/// just the single song — matching how tapping a track in an album normally behaves.
private struct WatchAlbumDetailView: View {
    let album: WatchAlbumGroup
    @Binding var selectedPage: WatchPage

    var body: some View {
        List(album.songs) { meta in
            WatchSongRow(meta: meta, queue: album.songs) { selectedPage = .nowPlaying }
        }
        .navigationTitle(album.album)
    }
}

/// A single tappable song row shared by the flat song list, the album detail list, and the
/// Queue & Volume page's "up next" list (see `WatchQueueVolumeView`): starts playback of `queue`
/// from `meta` and invokes `onSelect` (e.g. switching to Now Playing on the Library pages; a no-op
/// on the Queue page, which stays put). Offers "Delete" via a long-press context menu (see
/// `WatchSongListView`'s doc comment for why this replaced row swipe actions).
struct WatchSongRow: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    @EnvironmentObject private var player: WatchAudioPlayerService
    let meta: WatchTransferMeta
    let queue: [WatchTransferMeta]
    var onSelect: () -> Void = {}

    var body: some View {
        Button {
            player.play(meta, queue: queue)
            onSelect()
        } label: {
            HStack {
                WatchArtworkThumbnail(meta: meta)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.displayTitle)
                        .font(.body)
                        .lineLimit(1)
                    Text(meta.displayArtist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if player.currentSong?.id == meta.id {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                library.removeSong(id: meta.id)
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }
}

/// Small library-row thumbnail: the received-artwork JPEG if present, otherwise a generic note
/// glyph placeholder. Kept as its own view (rather than inline in the `List`) so each row only
/// re-reads its own artwork file, not the whole list's. `meta` is optional so the album list can
/// reuse this for `WatchAlbumGroup.artworkSong`, which is `nil` only for a (never-expected) empty
/// album.
private struct WatchArtworkThumbnail: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    let meta: WatchTransferMeta?

    var body: some View {
        ZStack {
            if let meta, let url = library.artworkFileURLIfPresent(for: meta), let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                Image(systemName: "music.note")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    WatchSongListView(selectedPage: .constant(.library))
        .environmentObject(WatchLocalLibrary())
        .environmentObject(WatchAudioPlayerService(library: WatchLocalLibrary()))
}
