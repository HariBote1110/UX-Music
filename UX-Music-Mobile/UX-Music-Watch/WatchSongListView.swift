import SwiftUI
import UIKit

/// Browse mode for the Library page: a flat list of every song, or songs grouped by album (see
/// `WatchAlbumGrouping`). Kept as a page-local `@State` rather than persisted — the Watch app is
/// small enough that re-opening on the default flat list each launch is not disorienting.
private enum WatchLibraryBrowseMode: String, CaseIterable {
    case songs = "Songs"
    case albums = "Albums"
}

/// Song list received from the iPhone. Tapping a row starts playback and switches to the
/// Now Playing page (see `WatchRootView`'s paged `TabView`). Deletion is a long-press context menu
/// rather than a row swipe: on watchOS the Library and Now Playing pages are themselves swiped
/// between horizontally (see `WatchRootView`), and a right-swipe on a list row was being captured
/// by the row's own `swipeActions` instead of the page `TabView`, making it impossible to swipe
/// from Library to Now Playing while a finger started on a row. A long press has no such conflict.
/// A segmented control at the top switches between the flat song list and albums grouped by
/// `WatchAlbumGrouping`; the currently-playing song is marked with a small speaker glyph in either
/// mode.
struct WatchSongListView: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    @EnvironmentObject private var player: WatchAudioPlayerService
    @Binding var selectedPage: WatchPage
    @State private var browseMode: WatchLibraryBrowseMode = .songs

    private var albums: [WatchAlbumGroup] { WatchAlbumGrouping.albums(from: library.songs) }

    var body: some View {
        NavigationStack {
            Group {
                if library.songs.isEmpty {
                    Text("No songs yet.\nTransfer from the iPhone app.")
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    VStack(spacing: 0) {
                        // `.segmented` is unavailable on watchOS; `.wheel` isn't right for a
                        // two-option toggle either, so this is rendered as a pair of plain
                        // buttons that behave like a segmented control.
                        HStack(spacing: 4) {
                            ForEach(WatchLibraryBrowseMode.allCases, id: \.self) { mode in
                                Button {
                                    browseMode = mode
                                } label: {
                                    Text(mode.rawValue)
                                        .font(.caption2)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 4)
                                        .background(browseMode == mode ? Color.blue : Color.secondary.opacity(0.2))
                                        .foregroundStyle(browseMode == mode ? .white : .primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)

                        switch browseMode {
                        case .songs:
                            songList(library.songs)
                        case .albums:
                            albumList
                        }
                    }
                }
            }
            .navigationTitle("Library")
        }
    }

    private func songList(_ songs: [WatchTransferMeta]) -> some View {
        List(songs) { meta in
            WatchSongRow(meta: meta, queue: songs, selectedPage: $selectedPage)
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
                        Text("\(album.songs.count) song\(album.songs.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// One song's worth of an album's track list, shown by `WatchAlbumDetailView`. Tapping a track
/// starts the whole album playing as the queue (in track order), positioned at that track — not
/// just the single song — matching how tapping a track in an album normally behaves.
private struct WatchAlbumDetailView: View {
    @EnvironmentObject private var player: WatchAudioPlayerService
    let album: WatchAlbumGroup
    @Binding var selectedPage: WatchPage

    var body: some View {
        List(album.songs) { meta in
            WatchSongRow(meta: meta, queue: album.songs, selectedPage: $selectedPage)
        }
        .navigationTitle(album.album)
    }
}

/// A single tappable song row shared by the flat song list and album detail list: starts playback
/// of `queue` from `meta` and switches to Now Playing on tap; offers "Delete" via a long-press
/// context menu (see `WatchSongListView`'s doc comment for why this replaced row swipe actions).
private struct WatchSongRow: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    @EnvironmentObject private var player: WatchAudioPlayerService
    let meta: WatchTransferMeta
    let queue: [WatchTransferMeta]
    @Binding var selectedPage: WatchPage

    var body: some View {
        Button {
            player.play(meta, queue: queue)
            selectedPage = .nowPlaying
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
                Label("Delete", systemImage: "trash")
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
