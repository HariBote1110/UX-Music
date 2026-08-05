import SwiftUI

/// Segment order mirrors the desktop sidebar: 曲 / アルバム / アーティスト / プレイリスト / For You.
private enum LocalViewMode: Int, CaseIterable {
    case songs, albums, artists, playlists, forYou

    var title: String {
        switch self {
        case .songs: return "曲"
        case .albums: return "アルバム"
        case .artists: return "アーティスト"
        case .playlists: return "プレイリスト"
        case .forYou: return "For You"
        }
    }
}

/// Not `private`: `ArtistDetailView` (a separate file, same `NavigationStack`) also pushes
/// `.album(_:)` routes onto this screen's path, so the type must be visible outside this file.
enum LibraryRoute: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(String)
}

struct LocalLibraryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewMode: LocalViewMode = .songs
    @State private var path = NavigationPath()
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var showDesktopPlaylistImport = false
    @State private var playlistEditMode: EditMode = .inactive
    @State private var searchQuery = ""

    private var downloaded: [Song] {
        model.sortedDownloadedSongsForLibrary
    }

    /// `downloaded` sorted by the user's chosen `librarySortOrder`; album-run grouping (task 1) is
    /// only meaningful when this equals `.album`, since any other order scatters an album's tracks.
    private var sortedSongs: [Song] {
        model.librarySortOrder.sorted(downloaded)
    }

    private var searchedSongs: [Song] {
        SongSearchFilter.filter(sortedSongs, query: searchQuery)
    }

    private var searchedAlbums: [Album] {
        let albums = Album.fromSongs(downloaded)
        guard !searchQuery.isEmpty else { return albums }
        return albums.filter { !SongSearchFilter.filter($0.songs, query: searchQuery).isEmpty }
    }

    private var searchedArtists: [Artist] {
        let artists = Artist.fromSongs(downloaded)
        guard !searchQuery.isEmpty else { return artists }
        return artists.filter { !SongSearchFilter.filter($0.songs, query: searchQuery).isEmpty }
    }

    private var forYouSections: [SituationPlaylistResolver.Section] {
        SituationPlaylistResolver.resolve(model.situationPlaylists, library: downloaded)
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
                    headerTrailing
                }
                if [.songs, .albums, .artists].contains(viewMode) {
                    searchField
                }
                Group {
                    switch viewMode {
                    case .songs:
                        if downloaded.isEmpty {
                            emptyState
                        } else {
                            songsContent(songs: searchedSongs)
                        }
                    case .albums:
                        if downloaded.isEmpty {
                            emptyState
                        } else {
                            albumContent(albums: searchedAlbums)
                        }
                    case .artists:
                        if downloaded.isEmpty {
                            emptyState
                        } else {
                            artistContent(artists: searchedArtists)
                        }
                    case .playlists:
                        playlistContent
                    case .forYou:
                        forYouContent
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
                case .artist(let artist):
                    ArtistDetailView(artist: artist)
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
            .task(id: viewMode) {
                guard viewMode == .forYou else { return }
                await model.refreshSituationPlaylists()
            }
        }
    }

    /// The header's trailing accessory is a single fixed-position slot shared by every segment
    /// (see `LibrarySegmentedHeader`): the playlist ellipsis menu on Playlists, the sort menu on
    /// Songs (task 3), reserved-but-empty space everywhere else so switching tabs never shifts
    /// the segmented control.
    @ViewBuilder
    private var headerTrailing: some View {
        switch viewMode {
        case .playlists:
            playlistActionsMenu
        case .songs:
            sortMenu
        default:
            Color.clear.frame(width: 32, height: 32)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("並び替え", selection: Bindable(model).librarySortOrder) {
                ForEach(LibrarySortOrder.allCases) { order in
                    Text(order.displayName).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
        }
        .modifier(LibraryHeaderGlassButtonStyle())
        .accessibilityLabel("並び替え")
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("曲・アーティスト・アルバムを検索", text: $searchQuery)
                .textFieldStyle(.plain)
        }
        .padding(10)
        .background(Color(red: 0.17, green: 0.17, blue: 0.18))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

        menu
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
                            WatchTransferBulkMenuItem(
                                title: "プレイリストを Apple Watch に転送",
                                songs: model.resolvedSongs(for: pl)
                            )
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
    private func albumContent(albums: [Album]) -> some View {
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
                    .contextMenu {
                        WatchTransferBulkMenuItem(
                            title: "アルバムを Apple Watch に転送",
                            songs: album.songs
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .padding(.bottom, 8)
        }
    }

    private func songsContent(songs: [Song]) -> some View {
        // Album-run grouping (task 1) only makes sense while songs are actually in album order —
        // under any other `librarySortOrder` an album's tracks are scattered, so `positions` would
        // draw misleading connectors between unrelated rows.
        let groupPositions: [AlbumGroupPosition]? =
            model.librarySortOrder == .album ? AlbumGrouping.positions(for: songs) : nil
        return List {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                SongRowView(
                    song: song,
                    artworkId: song.artworkId,
                    artworkURL: model.artworkURL(for: song.artworkId),
                    albumGroupPosition: groupPositions?[index],
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
                .contextMenu {
                    WatchTransferSongMenuItem(song: song)
                }
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

    @ViewBuilder
    private func artistContent(artists: [Artist]) -> some View {
        if artists.isEmpty {
            Text("一致するアーティストがありません")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(artists) { artist in
                    NavigationLink(value: LibraryRoute.artist(artist)) {
                        HStack(spacing: 12) {
                            ArtworkImageView(
                                artworkId: artist.artworkId,
                                urlString: model.artworkURL(for: artist.artworkId),
                                cornerRadius: 22,
                                size: 44
                            )
                            .frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.displayName)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(artist.albums.count) アルバム · \(artist.songs.count) 曲")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
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
                        WatchTransferBulkMenuItem(
                            title: "アーティストの曲を Apple Watch に転送",
                            songs: artist.songs
                        )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
        }
    }

    /// "For You": server-generated situational playlists (最近追加した曲/よく聴く曲/ランダムピック, …),
    /// resolved against the downloaded library via `SituationPlaylistResolver`. An empty
    /// `situationPlaylists` is the *normal* state for a desktop that predates the endpoint, so this
    /// shows a neutral explanation rather than an error.
    @ViewBuilder
    private var forYouContent: some View {
        if forYouSections.isEmpty {
            ContentUnavailableView {
                Label("For You はまだ空です", systemImage: "sparkles")
            } description: {
                Text("デスクトップ側の対応バージョンに更新すると、最近追加した曲やよく聴く曲がここに表示されます。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        } else {
            List {
                ForEach(forYouSections, id: \.name) { section in
                    Section(section.name) {
                        ForEach(section.songs) { song in
                            SongRowView(
                                song: song,
                                artworkId: song.artworkId,
                                artworkURL: model.artworkURL(for: song.artworkId),
                                onTap: {
                                    playLocal(song: song, in: section.songs)
                                }
                            )
                            .padding(.vertical, 4)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                            .listRowSeparator(.hidden)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(red: 0.07, green: 0.07, blue: 0.08))
                            )
                            .contextMenu {
                                WatchTransferSongMenuItem(song: song)
                            }
                        }
                    }
                    .headerProminence(.increased)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
        }
    }

    /// Resolves a Library song for playback: local file path for downloaded songs, unchanged for
    /// YouTube members (their `path`/`sourceURL` is the video URL, resolved by `MusicPlayerService`
    /// via `AppModel.resolveYouTubeVideoID` — no local file involved).
    private func resolvedForPlayback(_ song: Song) -> Song {
        song.isYouTube ? song : song.withPath(model.downloadManager.localPathString(songId: song.id))
    }

    private func playLocal(song: Song, in list: [Song]) {
        let playable = list.filter { model.isLibrarySongMember(songId: $0.id) }
        let localSong = resolvedForPlayback(song)
        let queue = playable.map { resolvedForPlayback($0) }
        Task {
            await model.player.play(localSong, newQueue: queue)
        }
    }
}
