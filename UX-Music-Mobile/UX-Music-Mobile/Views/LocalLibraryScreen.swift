import SwiftUI

private enum LocalViewMode: String, CaseIterable {
    case albums, songs
}

struct LocalLibraryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewMode: LocalViewMode = .albums

    private var downloaded: [Song] {
        model.downloadManager.downloadedSongs.values.sorted { $0.displayTitle < $1.displayTitle }
    }

    var body: some View {
        NavigationStack {
            Group {
                if downloaded.isEmpty {
                    emptyState
                } else {
                    content(songs: downloaded)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(downloaded.isEmpty ? "Library" : "Library (\(downloaded.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $viewMode) {
                        Text("Albums").tag(LocalViewMode.albums)
                        Text("Songs").tag(LocalViewMode.songs)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("No downloaded songs")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Download songs from Remote Library")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    @ViewBuilder
    private func content(songs: [Song]) -> some View {
        let albums = Album.fromSongs(songs)
        if viewMode == .albums {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(albums) { album in
                        localAlbumCard(album: album, allSongs: songs)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .padding(.bottom, 8)
            }
        } else {
            List {
                ForEach(songs) { song in
                    SongRowView(
                        song: song,
                        artworkURL: model.artworkURL(for: song.artworkId),
                        onTap: {
                            playLocal(song: song, in: songs)
                        }
                    )
                    .listRowBackground(Color(red: 0.07, green: 0.07, blue: 0.08))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.downloadManager.remove(songId: song.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
        }
    }

    private func localAlbumCard(album: Album, allSongs: [Song]) -> some View {
        Button {
            guard let first = album.songs.first else { return }
            playLocal(song: first, in: album.songs)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { geo in
                    let side = geo.size.width
                    ArtworkImageView(
                        urlString: model.artworkURL(for: album.artworkId),
                        cornerRadius: 10,
                        size: side
                    )
                    .frame(width: side, height: side)
                }
                .aspectRatio(1, contentMode: .fit)
                Text(album.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text("\(album.displayArtist) · \(album.songs.count) songs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func playLocal(song: Song, in list: [Song]) {
        let downloaded = list.filter { model.downloadManager.isDownloaded(songId: $0.id) }
        let localSong = song.withPath(model.downloadManager.localPathString(songId: song.id))
        let queue = downloaded.map { $0.withPath(model.downloadManager.localPathString(songId: $0.id)) }
        Task {
            await model.player.play(localSong, newQueue: queue)
        }
    }
}
