import SwiftUI

private enum LocalViewMode: Int, CaseIterable {
    case albums, playlists, songs

    var title: String {
        switch self {
        case .albums: return "Albums"
        case .playlists: return "Playlists"
        case .songs: return "Songs"
        }
    }
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
    @State private var playlistEditMode: EditMode = .inactive

    private var downloaded: [Song] {
        model.sortedDownloadedSongsForLibrary
    }

    private var viewModeIndex: Binding<Int> {
        Binding(
            get: { viewMode.rawValue },
            set: { newValue in
                if let mode = LocalViewMode(rawValue: newValue) { viewMode = mode }
            }
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                LibrarySegmentedHeader(
                    segments: LocalViewMode.allCases.map(\.title),
                    selectedIndex: viewModeIndex
                ) {
                    playlistActionsMenu
                }
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
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            .environment(\.editMode, $playlistEditMode)
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

    @ViewBuilder
    private var playlistActionsMenu: some View {
        let menu = Menu {
            if model.serverConfig.isConfigured {
                Button {
                    showDesktopPlaylistImport = true
                } label: {
                    Label("デスクトップから取り込む", systemImage: "arrow.down.doc")
                }
            }
            Button {
                playlistEditMode = playlistEditMode == .active ? .inactive : .active
            } label: {
                Label(
                    playlistEditMode == .active ? "並べ替えを終了" : "並べ替え",
                    systemImage: "arrow.up.arrow.down"
                )
            }
            Button {
                newPlaylistName = ""
                showNewPlaylistAlert = true
            } label: {
                Label("新規プレイリスト", systemImage: "plus")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
        }
        .modifier(LibraryHeaderGlassButtonStyle())
        .disabled(viewMode != .playlists)

        // `.hidden()` (not `.opacity(0)`) so the `.ultraThinMaterial` circle backdrop is fully
        // unrendered on non-Playlists tabs — a sibling background would otherwise stay faintly
        // visible even at opacity 0. Layout space is still reserved (hidden views keep their size).
        if viewMode == .playlists {
            menu
        } else {
            menu.hidden()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No downloaded songs",
            systemImage: "music.note.list",
            description: Text("Download songs from Remote Library")
        )
    }

    @ViewBuilder
    private var playlistContent: some View {
        if model.playlists.isEmpty {
            ContentUnavailableView {
                Label("まだプレイリストがありません", systemImage: "music.note.list")
            } description: {
                Text("+ で新規作成するか、デスクトップから取り込めます。")
            } actions: {
                if model.serverConfig.isConfigured {
                    Button {
                        showDesktopPlaylistImport = true
                    } label: {
                        Label("デスクトップのプレイリストを取り込む", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        } else {
            List {
                Section {
                    ForEach(model.playlists) { pl in
                        NavigationLink(value: LibraryRoute.playlist(pl.id)) {
                            HStack(spacing: 12) {
                                ArtworkImageView(
                                    artworkId: model.artworkIdForPlaylist(pl),
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
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.07, green: 0.07, blue: 0.08))
                        )
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
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
        }
    }

    @ViewBuilder
    private func albumContent(songs: [Song]) -> some View {
        let albums = Album.fromSongs(songs)
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(albums) { album in
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
                            Text("\(album.displayArtist) · \(album.songs.count) songs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 8)
        }
    }

    private func songsContent(songs: [Song]) -> some View {
        List {
            ForEach(songs) { song in
                SongRowView(
                    song: song,
                    artworkId: song.artworkId,
                    artworkURL: model.artworkURL(for: song.artworkId),
                    onTap: {
                        playLocal(song: song, in: songs)
                    }
                )
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowSeparator(.hidden)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.07, green: 0.07, blue: 0.08))
                )
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
