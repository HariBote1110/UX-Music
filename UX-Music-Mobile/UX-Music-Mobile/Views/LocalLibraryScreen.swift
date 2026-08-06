import SwiftUI

/// Segment order mirrors the desktop sidebar: 曲 / アルバム / アーティスト / プレイリスト.
///
/// Four segments is the most the native `.segmented` Picker fits without truncating a Japanese
/// label (it apportions segments equally), and it is also what the paged `TabView` swipes between —
/// the two have to agree, so adding a segment means re-checking both.
private enum LocalViewMode: Int, CaseIterable, Hashable {
    case songs, albums, artists, playlists

    var title: String {
        switch self {
        case .songs: return "曲"
        case .albums: return "アルバム"
        case .artists: return "アーティスト"
        case .playlists: return "プレイリスト"
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
    /// Separate from `searchQuery`: the playlists page filters by playlist name, not by song tags,
    /// so carrying a song search across the page swipe would silently hide every playlist.
    @State private var playlistQuery = ""

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
                )
                // Horizontal swipe pages between segments (the Picker above stays in sync via
                // `viewMode`). Row-level `swipeActions` were removed from every list on this screen
                // because they swallow the page gesture whenever a swipe starts on a row — the same
                // conflict `WatchSongListView` hit; per-song destructive actions moved to the
                // long-press context menu instead.
                TabView(selection: $viewMode) {
                    page { songsPane }.tag(LocalViewMode.songs)
                    page { albumsPane }.tag(LocalViewMode.albums)
                    page { artistsPane }.tag(LocalViewMode.artists)
                    page { playlistsPane }.tag(LocalViewMode.playlists)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
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
            .alert("新規プレイリスト", isPresented: $showNewPlaylistAlert) {
                TextField("名前", text: $newPlaylistName)
                Button("作成") {
                    let name = newPlaylistName
                    newPlaylistName = ""
                    try? model.createPlaylist(name: name)
                }
                Button("キャンセル", role: .cancel) {
                    newPlaylistName = ""
                }
            } message: {
                Text("新しいプレイリストの名前を入力してください。")
            }
        }
    }

    /// Every page fills the paged `TabView` so the four segments are the same height and the swipe
    /// gesture is live over the whole area, not just where a page happens to have content.
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var songsPane: some View {
        VStack(spacing: 0) {
            LibrarySearchRow(query: $searchQuery) { sortMenu }
            if downloaded.isEmpty {
                emptyState
            } else {
                songsContent(songs: searchedSongs)
            }
        }
    }

    @ViewBuilder
    private var albumsPane: some View {
        VStack(spacing: 0) {
            LibrarySearchRow(query: $searchQuery) { emptyAccessory }
            if downloaded.isEmpty {
                emptyState
            } else {
                albumContent(albums: searchedAlbums)
            }
        }
    }

    @ViewBuilder
    private var artistsPane: some View {
        VStack(spacing: 0) {
            LibrarySearchRow(query: $searchQuery) { emptyAccessory }
            if downloaded.isEmpty {
                emptyState
            } else {
                artistContent(artists: searchedArtists)
            }
        }
    }

    @ViewBuilder
    private var playlistsPane: some View {
        VStack(spacing: 0) {
            LibrarySearchRow(query: $playlistQuery, prompt: "プレイリストを検索") {
                playlistActionsMenu
            }
            playlistContent
        }
    }

    /// Reserved-but-empty accessory slot so every page's search field is the same width.
    private var emptyAccessory: some View {
        Color.clear.frame(width: 32, height: 32)
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

    private var searchedPlaylists: [Playlist] {
        let query = playlistQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.playlists }
        return model.playlists.filter { $0.name.lowercased().contains(query) }
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
            "ダウンロード済みの曲がありません",
            systemImage: "music.note.list",
            description: Text("リモートライブラリから曲をダウンロードしてください")
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
        } else if searchedPlaylists.isEmpty {
            Text("一致するプレイリストがありません")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(searchedPlaylists) { pl in
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
                                    Text("\(pl.songIds.count) 曲")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(height: SongRowMetrics.rowHeight)
                        }
                        .modifier(LibraryListRowStyle())
                        .contextMenu {
                            Button {
                                playlistEditMode = playlistEditMode == .active ? .inactive : .active
                            } label: {
                                Label("並べ替え", systemImage: "arrow.up.arrow.down")
                            }
                            WatchTransferBulkMenuItem(
                                title: "プレイリストを Apple Watch に転送",
                                songs: model.resolvedSongs(for: pl)
                            )
                            Button(role: .destructive) {
                                try? model.deletePlaylist(id: pl.id)
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                    // Only while unfiltered: `movePlaylists` takes offsets into `model.playlists`,
                    // which a filtered `searchedPlaylists` no longer lines up with.
                    .onMove(perform: playlistQuery.isEmpty ? { source, destination in
                        try? model.movePlaylists(fromOffsets: source, toOffset: destination)
                    } : nil)
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
                            Text("\(album.displayArtist) · \(album.songs.count) 曲")
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
                .modifier(LibraryListRowStyle())
                .contextMenu {
                    SongQueueMenuItems(song: resolvedForPlayback(song))
                    AddSongToPlaylistMenuItem(songId: song.id)
                    WatchTransferSongMenuItem(song: song)
                    Button(role: .destructive) {
                        model.removeDownloadedSong(songId: song.id)
                    } label: {
                        Label("ライブラリから削除", systemImage: "trash")
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
                        .frame(height: SongRowMetrics.rowHeight)
                    }
                    .modifier(LibraryListRowStyle())
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
