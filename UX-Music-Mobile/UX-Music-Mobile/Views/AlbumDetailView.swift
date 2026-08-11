import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let album: Album

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
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                HStack {
                    Text(album.displayArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(album.songs.count) 曲")
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
                    Label("アルバムをダウンロード", systemImage: "arrow.down.circle")
                }
            }
            WatchTransferBulkMenuItem(
                title: "Transfer Album to Apple Watch",
                songs: album.songs
            )
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
            await model.player.play(song, newQueue: [song])
        }
    }

    private func play(_ song: Song) {
        let downloaded = album.songs.filter { model.isSongDownloaded(songId: $0.id) }
        let localSong = song.withPath(model.downloadManager.localPathString(songId: song.id))
        let queue = downloaded.map { $0.withPath(model.downloadManager.localPathString(songId: $0.id)) }
        Task {
            await model.player.play(localSong, newQueue: queue)
        }
    }
}
