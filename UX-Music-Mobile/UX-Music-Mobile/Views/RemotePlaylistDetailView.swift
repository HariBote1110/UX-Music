import SwiftUI

/// Desktop playlist opened from Remote Library: same layout idea as `AlbumDetailView`, order follows desktop `songIds`.
struct RemotePlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: RemoteDesktopPlaylist

    private var resolvedSongs: [Song] {
        guard case .loaded(let library) = model.libraryState else { return [] }
        var byId: [String: Song] = [:]
        for s in library { byId[s.id] = s }
        return playlist.songIds.compactMap { byId[$0] }
    }

    private var artworkId: String {
        resolvedSongs.first { !$0.artworkId.isEmpty }?.artworkId ?? ""
    }

    /// Whether `model.libraryState` has actually resolved (loaded, even to zero songs) — as
    /// opposed to still being `.idle`/`.loading`/`.failed`, in which case `resolvedSongs` reads as
    /// empty for a reason unrelated to the playlist genuinely having no matching songs.
    private var isLibraryLoaded: Bool {
        if case .loaded = model.libraryState { return true }
        return false
    }

    var body: some View {
        LibraryBottomBleed { bottomInset in
            scrollBody
                .contentMargins(.bottom, bottomInset, for: .scrollContent)
        }
        .background(Color.black)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if model.playlistSongsContainUndownloaded(resolvedSongs) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.downloadPlaylistSongs(resolvedSongs) }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .accessibilityLabel("Download Playlist")
                }
            }
        }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Desktop Playlist")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(format: String(localized: "%ld Songs"), resolvedSongs.count))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if let missing = playlist.pathsNotInLibrary, !missing.isEmpty {
                    Text(String(format: String(localized: "Paths skipped (not in library): %ld"), missing.count))
                        .font(.footnote)
                        .foregroundStyle(.orange.opacity(0.9))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                // Not-yet-resolved (library still loading) gets a fixed-size skeleton rather than
                // the "no songs" empty state: the Album → Playlist push transition can land here
                // before `libraryState` finishes loading, and if the pushed view's laid-out height
                // is still the tiny empty-state message at that instant, the push animation shows
                // the destination sized wrong for a frame (the glitch this screen used to produce
                // on a first launch, before the Remote tab's library had ever loaded).
                if !isLibraryLoaded {
                    placeholderSongRows
                } else if resolvedSongs.isEmpty {
                    Text("This playlist has no matching songs in the remote library. Refresh the library and try again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                } else {
                    ForEach(resolvedSongs) { song in
                        SongRowView(
                            song: song,
                            artworkId: song.artworkId,
                            artworkURL: model.artworkURL(for: song.artworkId),
                            showTrackNumber: false,
                            onTap: rowTap(for: song),
                            trailing: {
                                SongRowDownloadTrailing(song: song)
                            }
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contextMenu {
                            WatchTransferSongMenuItem(song: song)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// One placeholder row per expected song (from `playlist.songIds`, capped so a huge playlist
    /// doesn't render hundreds of skeleton rows) at the same row height `SongRowView` occupies, so
    /// the screen's total laid-out height while the library is still loading closely matches its
    /// eventual real height instead of collapsing to the one-line empty-state message.
    private var placeholderSongRows: some View {
        VStack(spacing: 0) {
            ForEach(0..<min(playlist.songIds.count, 8), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 56)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottom) {
            if artworkId.isEmpty {
                playlistPlaceholderArtwork
            } else {
                WearCachedHeroArtworkView(
                    artworkId: artworkId,
                    urlString: model.artworkURL(for: artworkId),
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
            if model.playlistSongsContainUndownloaded(resolvedSongs) {
                Button {
                    Task { await model.downloadPlaylistSongs(resolvedSongs) }
                } label: {
                    Label("Download Playlist", systemImage: "arrow.down.circle")
                }
            }
            WatchTransferBulkMenuItem(
                title: "Transfer Playlist to Apple Watch",
                songs: resolvedSongs
            )
        }
    }

    private var playlistPlaceholderArtwork: some View {
        ZStack {
            Color(white: 0.12)
            Image(systemName: "music.note.list")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.white.opacity(0.22))
        }
        .frame(height: 280)
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
            await model.player.play(song, newQueue: [song])
        }
    }

    private func play(_ song: Song) {
        let downloaded = resolvedSongs.filter { model.isSongDownloaded(songId: $0.id) }
        let localSong = song.withPath(model.downloadManager.localPathString(songId: song.id))
        let queue = downloaded.map { $0.withPath(model.downloadManager.localPathString(songId: $0.id)) }
        Task {
            await model.player.play(localSong, newQueue: queue)
        }
    }
}
