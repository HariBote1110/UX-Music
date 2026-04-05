import SwiftUI

struct AlbumDetailView: View {
    @Environment(AppModel.self) private var model
    let album: Album

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                HStack {
                    Text(album.displayArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(album.songs.count) songs")
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
                        onTap: model.isSongDownloaded(songId: song.id)
                            ? { play(song) }
                            : nil,
                        trailing: {
                            trailing(for: song)
                        }
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(.bottom, 8)
        }
        .background(Color.black)
        .navigationTitle(album.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
                    Label("Download album", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func trailing(for song: Song) -> some View {
        if model.isSongDownloaded(songId: song.id) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 20))
        } else if model.downloadProgress[song.id] != nil {
            ProgressView()
                .frame(width: 22, height: 22)
        } else {
            Button {
                Task { await model.downloadSong(song) }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
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
