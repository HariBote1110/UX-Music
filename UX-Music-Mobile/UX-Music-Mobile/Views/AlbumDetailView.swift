import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let album: Album

    private var shuffleReference: PlaybackCollectionRef {
        PlaybackCollectionRef(kind: .album, key: album.id)
    }

    var body: some View {
        LibraryBottomBleed { bottomInset in
            scrollBody
                .contentMargins(.bottom, bottomInset, for: .scrollContent)
        }
        .background(Color.black)
        .navigationTitle(album.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CollectionShuffleMenuButton(reference: shuffleReference)
            }
        }
    }

    private var scrollBody: some View {
        ScrollView {
            // Lazy: long song lists only build the rows that are on screen.
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                HStack {
                    Text(album.displayArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: String(localized: "%ld Songs"), album.songs.count))
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                ForEach(album.songs) { song in
                    SongRowView(
                        song: song,
                        artworkId: song.artworkId,
                        artworkURL: model.artworkURL(for: song.artworkId),
                        showTrackNumber: true,
                        onTap: rowTap(for: song),
                        trailing: {
                            SongRowDownloadTrailing(song: song)
                        }
                    )
                    .padding(.horizontal, SongRowMetrics.horizontalInset)
                    .contextMenu {
                        WatchTransferSongMenuItem(song: song)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var header: some View {
        ZStack(alignment: .bottom) {
            if album.artworkId.isEmpty {
                Color(white: 0.12)
                    .frame(height: 280)
            } else {
                WearCachedHeroArtworkView(
                    artworkId: album.artworkId,
                    urlString: model.artworkURL(for: album.artworkId),
                    height: 280
                )
            }
            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 280)
        }
        .frame(height: 280)
        .contextMenu {
            if model.albumHasTracksToDownload(album) {
                Button {
                    Task { await model.downloadAlbum(album) }
                } label: {
                    Label("Download Album", systemImage: "arrow.down.circle")
                }
            }
            WatchTransferBulkMenuItem(
                title: "Transfer Album to Apple Watch",
                songs: album.songs
            )
            Menu {
                CollectionShufflePreferencePicker(reference: shuffleReference)
            } label: {
                Label("Default Shuffle", systemImage: "shuffle")
            }
        }
    }

    private func rowTap(for song: Song) -> (() -> Void)? {
        switch song.rowTapAction(isDownloaded: model.isSongDownloaded(songId: song.id)) {
        case .openYouTubePlayer: return { playYouTube(song) }
        case .playDownloaded: return { play(song) }
        case .none: return nil
        }
    }

    /// Plays a YouTube song as a normal single-song queue, exactly like tapping any local
    /// song — no dedicated YouTube player screen any more (see
    /// `progress/mobile-youtube-embed.md`).
    private func playYouTube(_ song: Song) {
        Task {
            await model.player.play(song, newQueue: [song], collection: shuffleReference)
        }
    }

    private func play(_ song: Song) {
        let downloaded = album.songs.filter { model.isSongDownloaded(songId: $0.id) }
        let localSong = song.withPath(model.downloadManager.localPathString(songId: song.id))
        let queue = downloaded.map { $0.withPath(model.downloadManager.localPathString(songId: $0.id)) }
        Task {
            await model.player.play(localSong, newQueue: queue, collection: shuffleReference)
        }
    }
}

// MARK: - Collection shuffle preference control

/// Per-collection default shuffle control shared by `AlbumDetailView`, `PlaylistDetailView` and
/// `RemotePlaylistDetailView` (toolbar button) plus their long-press context menus and the album
/// grid / playlist list rows in `LocalLibraryScreen`. See `CollectionShufflePreferenceStore`.
struct CollectionShuffleMenuButton: View {
    @Environment(AppModel.self) private var model
    let reference: PlaybackCollectionRef

    private var current: CollectionShufflePreference? {
        model.collectionShufflePreferenceStore.preference(for: reference)
    }

    private var iconName: String {
        switch current {
        case .on: return "shuffle"
        case .off: return "list.number"
        case nil: return "shuffle"
        }
    }

    var body: some View {
        Menu {
            CollectionShufflePreferencePicker(reference: reference)
        } label: {
            Image(systemName: iconName)
                .foregroundStyle(current == nil ? .secondary : .primary)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch current {
        case .on: return String(localized: "Default Shuffle: Shuffle")
        case .off: return String(localized: "Default Shuffle: In Order")
        case nil: return String(localized: "Default Shuffle: Follow Normal Setting")
        }
    }
}

/// The three-way picker content (unset / shuffle / in order) for a collection's default shuffle
/// preference, meant to sit inside a `Menu`.
struct CollectionShufflePreferencePicker: View {
    @Environment(AppModel.self) private var model
    let reference: PlaybackCollectionRef

    private var current: CollectionShufflePreference? {
        model.collectionShufflePreferenceStore.preference(for: reference)
    }

    var body: some View {
        Picker(
            selection: Binding(
                get: { current },
                set: { model.collectionShufflePreferenceStore.setPreference($0, for: reference) }
            )
        ) {
            Label("Follow Normal Setting", systemImage: "circle.slash")
                .tag(Optional<CollectionShufflePreference>.none)
            Label("Shuffle", systemImage: "shuffle")
                .tag(Optional(CollectionShufflePreference.on))
            Label("In Order", systemImage: "list.number")
                .tag(Optional(CollectionShufflePreference.off))
        } label: {
            Text("Default Shuffle")
        }
    }
}
