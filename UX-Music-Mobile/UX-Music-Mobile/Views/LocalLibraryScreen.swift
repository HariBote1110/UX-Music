import SwiftUI

private enum LocalViewMode: String, CaseIterable {
    case albums, playlists, songs
}

private enum LibraryRoute: Hashable {
    case album(Album)
    case playlist(String)
}

struct LocalLibraryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewMode: LocalViewMode = .albums
    @State private var path = NavigationPath()
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var showDesktopPlaylistImport = false

    private var downloaded: [Song] {
        model.sortedDownloadedSongsForLibrary
    }

    private var navigationTitleText: String {
        switch viewMode {
        case .playlists:
            return model.playlists.isEmpty ? "Library" : "Library (\(model.playlists.count) playlists)"
        default:
            return downloaded.isEmpty ? "Library" : "Library (\(downloaded.count))"
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch viewMode {
                case .albums:
                    if downloaded.isEmpty {
                        emptyState
                    } else {
                        albumContent(songs: downloaded)
                    }
                case .playlists:
                    playlistContent
                case .songs:
                    if downloaded.isEmpty {
                        emptyState
                    } else {
                        songsContent(songs: downloaded)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $viewMode) {
                        Text("Albums").tag(LocalViewMode.albums)
                        Text("Playlists").tag(LocalViewMode.playlists)
                        Text("Songs").tag(LocalViewMode.songs)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewMode == .playlists {
                        HStack {
                            if model.serverConfig.isConfigured {
                                Button {
                                    showDesktopPlaylistImport = true
                                } label: {
                                    Image(systemName: "arrow.down.doc")
                                }
                                .accessibilityLabel("Import playlists from desktop")
                            }
                            EditButton()
                            Button {
                                newPlaylistName = ""
                                showNewPlaylistAlert = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("New playlist")
                        }
                    }
                }
            }
            .sheet(isPresented: $showDesktopPlaylistImport) {
                DesktopPlaylistImportView(isPresented: $showDesktopPlaylistImport)
                    .environment(model)
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .album(let album):
                    AlbumDetailView(album: album)
                case .playlist(let id):
                    PlaylistDetailView(playlistId: id)
                }
            }
            .alert("New playlist", isPresented: $showNewPlaylistAlert) {
                TextField("Name", text: $newPlaylistName)
                Button("Create") {
                    let name = newPlaylistName
                    newPlaylistName = ""
                    try? model.createPlaylist(name: name)
                }
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
            } message: {
                Text("Enter a name for the new playlist.")
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

    private var playlistContent: some View {
        List {
            if model.playlists.isEmpty {
                VStack(spacing: 18) {
                    Text("まだプレイリストがありません。+ で新規作成するか、デスクトップから取り込めます。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if model.serverConfig.isConfigured {
                        Button {
                            showDesktopPlaylistImport = true
                        } label: {
                            Label("デスクトップのプレイリストを取り込む", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Text("設定でデスクトップに接続すると、ここからプレイリストを取り込めます。")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .listRowBackground(Color(red: 0.07, green: 0.07, blue: 0.08))
            } else {
                Section {
                    ForEach(model.playlists) { pl in
                        NavigationLink(value: LibraryRoute.playlist(pl.id)) {
                            HStack(spacing: 12) {
                                ArtworkImageView(
                                    urlString: model.artworkURL(for: model.artworkIdForPlaylist(pl)),
                                    cornerRadius: 6,
                                    size: 44
                                )
                                .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pl.name)
                                        .font(.body.weight(.semibold))
                                    Text("\(pl.songIds.count) songs")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .listRowBackground(Color(red: 0.07, green: 0.07, blue: 0.08))
                        .contextMenu {
                            Button(role: .destructive) {
                                try? model.deletePlaylist(id: pl.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                try? model.deletePlaylist(id: pl.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { source, destination in
                        try? model.movePlaylists(fromOffsets: source, toOffset: destination)
                    }
                } footer: {
                    if model.serverConfig.isConfigured {
                        Button {
                            showDesktopPlaylistImport = true
                        } label: {
                            Label("デスクトップからプレイリストを追加", systemImage: "arrow.down.doc")
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }

    @ViewBuilder
    private func albumContent(songs: [Song]) -> some View {
        let albums = Album.fromSongs(songs)
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(albums) { album in
                    NavigationLink(value: LibraryRoute.album(album)) {
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .padding(.bottom, 8)
        }
    }

    private func songsContent(songs: [Song]) -> some View {
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
                        model.removeDownloadedSong(songId: song.id)
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

    private func playLocal(song: Song, in list: [Song]) {
        let downloaded = list.filter { model.isSongDownloaded(songId: $0.id) }
        let localSong = song.withPath(model.downloadManager.localPathString(songId: song.id))
        let queue = downloaded.map { $0.withPath(model.downloadManager.localPathString(songId: $0.id)) }
        Task {
            await model.player.play(localSong, newQueue: queue)
        }
    }
}
