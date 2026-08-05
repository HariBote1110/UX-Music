import SwiftUI

/// Detail screen for one `Artist` bucket (see `Artist.fromSongs`): the artist's albums as a grid,
/// then every one of their songs as a flat list below. Mirrors `AlbumDetailView`'s layout/styling
/// so the two detail screens read as one system.
struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    let artist: Artist

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                HStack {
                    Text("\(artist.albums.count) アルバム")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(artist.songs.count) 曲")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if !artist.albums.isEmpty {
                    albumsGrid
                        .padding(.bottom, 8)
                }

                ForEach(artist.songs) { song in
                    SongRowView(
                        song: song,
                        artworkId: song.artworkId,
                        artworkURL: model.artworkURL(for: song.artworkId),
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
            .padding(.bottom, 8)
        }
        .background(Color.black)
        .navigationTitle(artist.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var header: some View {
        ZStack(alignment: .bottom) {
            if artist.artworkId.isEmpty {
                Color(white: 0.12)
                    .frame(height: 200)
            } else {
                WearCachedHeroArtworkView(
                    artworkId: artist.artworkId,
                    urlString: model.artworkURL(for: artist.artworkId),
                    height: 200
                )
            }
            LinearGradient(
                colors: [.clear, .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 200)
        }
        .frame(height: 200)
        .contextMenu {
            WatchTransferBulkMenuItem(
                title: "アーティストの曲を Apple Watch に転送",
                songs: artist.songs
            )
        }
    }

    private var albumsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            ForEach(artist.albums) { album in
                NavigationLink(value: LibraryRoute.album(album)) {
                    VStack(alignment: .leading, spacing: 7) {
                        GeometryReader { geo in
                            let side = geo.size.width
                            ArtworkImageView(
                                artworkId: album.artworkId,
                                urlString: model.artworkURL(for: album.artworkId),
                                cornerRadius: 12,
                                size: side
                            )
                            .frame(width: side, height: side)
                            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        Text(album.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text("\(album.songs.count) 曲")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    WatchTransferBulkMenuItem(
                        title: "アルバムを Apple Watch に転送",
                        songs: album.songs
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
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
        let downloaded = artist.songs.filter { model.isSongDownloaded(songId: $0.id) }
        let localSong = song.withPath(model.downloadManager.localPathString(songId: song.id))
        let queue = downloaded.map { $0.withPath(model.downloadManager.localPathString(songId: $0.id)) }
        Task {
            await model.player.play(localSong, newQueue: queue)
        }
    }
}
