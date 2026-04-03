import SwiftUI

/// Desktop playlist opened from Remote Library: same layout idea as `AlbumDetailView`, order follows desktop `songIds`.
struct RemotePlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: WearDesktopPlaylist

    private var resolvedSongs: [Song] {
        guard case .loaded(let library) = model.libraryState else { return [] }
        var byId: [String: Song] = [:]
        for s in library { byId[s.id] = s }
        return playlist.songIds.compactMap { byId[$0] }
    }

    private var artworkId: String {
        resolvedSongs.first { !$0.artworkId.isEmpty }?.artworkId ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("デスクトップのプレイリスト")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\(resolvedSongs.count) 曲")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if let missing = playlist.pathsNotInLibrary, !missing.isEmpty {
                    Text("ライブラリに無いためスキップされたパス: \(missing.count) 件")
                        .font(.footnote)
                        .foregroundStyle(.orange.opacity(0.9))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                if resolvedSongs.isEmpty {
                    Text("このプレイリストに対応する曲がリモート一覧にありません。ライブラリを更新してから再度お試しください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                } else {
                    ForEach(resolvedSongs) { song in
                        SongRowView(
                            song: song,
                            artworkURL: model.artworkURL(for: song.artworkId),
                            showTrackNumber: false,
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
            }
            .padding(.bottom, 8)
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
                    .accessibilityLabel("プレイリストをダウンロード")
                }
            }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottom) {
            if artworkId.isEmpty {
                playlistPlaceholderArtwork
            } else {
                AsyncImage(url: URL(string: model.artworkURL(for: artworkId))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Color(white: 0.12)
                    }
                }
                .frame(height: 280)
                .clipped()
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
                    Label("プレイリストをダウンロード", systemImage: "arrow.down.circle")
                }
            }
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
        let downloaded = resolvedSongs.filter { model.isSongDownloaded(songId: $0.id) }
        let localSong = song.withPath(model.downloadManager.localPathString(songId: song.id))
        let queue = downloaded.map { $0.withPath(model.downloadManager.localPathString(songId: $0.id)) }
        Task {
            await model.player.play(localSong, newQueue: queue)
        }
    }
}
