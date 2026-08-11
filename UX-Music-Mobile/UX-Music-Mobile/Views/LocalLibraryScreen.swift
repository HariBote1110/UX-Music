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
        case .songs: return String(localized: "Songs")
        case .albums: return String(localized: "Albums")
        case .artists: return String(localized: "Artists")
        case .playlists: return String(localized: "Playlists")
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
        let albums = model.albumSortOrder.sorted(Album.fromSongs(downloaded))
        guard !searchQuery.isEmpty else { return albums }
        return albums.filter { !SongSearchFilter.filter($0.songs, query: searchQuery).isEmpty }
    }

    private var searchedArtists: [Artist] {
        let artists = model.artistSortOrder.sorted(Artist.fromSongs(downloaded))
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
            // Horizontal swipe pages between segments (the Picker in the header stays in sync via
            // `viewMode`). Row-level `swipeActions` were removed from every list on this screen
            // because they swallow the page gesture whenever a swipe starts on a row — the same
            // conflict `WatchSongListView` hit; per-song destructive actions moved to the
            // long-press context menu instead.
            //
            // The header is a top `safeAreaInset` rather than the first element of a `VStack`:
            // stacking it above the pages shrinks each page's frame, so its list stops dead at the
            // tab bar instead of running underneath it. As an inset the pages keep the full screen
            // height and every list scrolls under both the header and the floating tab bar, with
            // the scroll content inset automatically so nothing ends up unreachable.
            // `GeometryReader` + `ignoresSafeArea(.bottom)`: a paged `TabView` insets its pages by
            // the safe area, so a list inside one stops dead at the tab bar instead of running
            // under it. Letting the pages reach the screen's bottom edge and re-applying the inset
            // as *scroll content* margin gives the intended look — rows pass behind the floating
            // tab bar — while keeping the last row scrollable clear of it. Reading the inset from
            // the proxy (rather than hard-coding it) is what keeps the margin exact.
            //
            // The header stays stacked above the pages rather than being a top `safeAreaInset`:
            // the paged `TabView` does not pass an inset from that modifier down to its pages
            // either, so the first row would start underneath the header with nothing to push it
            // clear.
            LibraryBottomBleed { bottomInset in
                VStack(spacing: 0) {
                    header
                    TabView(selection: $viewMode) {
                        page(bottomInset: bottomInset) { songsPane }
                            .tag(LocalViewMode.songs)
                        page(bottomInset: bottomInset) { albumsPane }
                            .tag(LocalViewMode.albums)
                        page(bottomInset: bottomInset) { artistsPane }
                            .tag(LocalViewMode.artists)
                        page(bottomInset: bottomInset) { playlistsPane }
                            .tag(LocalViewMode.playlists)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
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

    /// Every page fills the paged `TabView` so the four segments are the same height and the swipe
    /// gesture is live over the whole area, not just where a page happens to have content.
    /// `bottomInset` is the tab bar's safe area, re-applied to the page's scroll content because
    /// the pages themselves now extend past it (see `body`).
    private func page<Content: View>(
        bottomInset: CGFloat,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
    }

    /// Segmented picker plus the current segment's search row, stacked above the pages.
    private var header: some View {
        VStack(spacing: 0) {
            LibrarySegmentedHeader(
                segments: LocalViewMode.allCases.map(\.title),
                selectedIndex: viewModeIndex
            )
            searchRow
        }
        .background(Color.black)
    }

    /// Routes the shared search field to the right query for the current tab. Playlists filters by
    /// playlist name rather than song tags (see `playlistQuery`'s declaration), everything else
    /// shares `searchQuery`.
    private var searchQueryBinding: Binding<String> {
        viewMode == .playlists ? $playlistQuery : $searchQuery
    }

    private var searchPrompt: String {
        viewMode == .playlists ? String(localized: "Search Playlists") : String(localized: "Search Songs, Artists, Albums")
    }

    /// One `LibrarySearchRow` instance shared by every tab (rather than a separate instance per
    /// `viewMode`, as this used to be) so paging between tabs updates only the accessory — see
    /// `headerAccessory` — instead of tearing down and rebuilding the whole row, which is what made
    /// the accessory icon pop in/out instead of animating. The field's prompt and bound query still
    /// switch per tab, but that swap is instant (no `.animation` wraps this row), so it reads as an
    /// ordinary state change rather than something visibly animating.
    private var searchRow: some View {
        LibrarySearchRow(query: searchQueryBinding, prompt: searchPrompt) {
            headerAccessory
        }
    }

    /// Cross-fades between the per-tab accessory buttons. Every tab shows a sort menu with the same
    /// icon now except playlists (`ellipsis.circle`), so in practice this only visibly animates on
    /// transitions into/out of the playlists tab. The `.animation` is scoped to this `ZStack` alone
    /// (not to `searchRow`, which contains the search field and would otherwise animate too) —
    /// see `searchRow`'s doc comment.
    @ViewBuilder
    private var headerAccessory: some View {
        ZStack {
            switch viewMode {
            case .songs:
                sortMenu.transition(.opacity)
            case .albums:
                albumSortMenu.transition(.opacity)
            case .artists:
                artistSortMenu.transition(.opacity)
            case .playlists:
                playlistActionsMenu.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewMode)
    }

    @ViewBuilder
    private var songsPane: some View {
        if downloaded.isEmpty {
            emptyState
        } else {
            songsContent(songs: searchedSongs)
        }
    }

    @ViewBuilder
    private var albumsPane: some View {
        if downloaded.isEmpty {
            emptyState
        } else {
            albumContent(albums: searchedAlbums)
        }
    }

    @ViewBuilder
    private var artistsPane: some View {
        if downloaded.isEmpty {
            emptyState
        } else {
            artistContent(artists: searchedArtists)
        }
    }

    private var playlistsPane: some View {
        playlistContent
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Bindable(model).librarySortOrder) {
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
        .accessibilityLabel("Sort")
    }

    private var albumSortMenu: some View {
        Menu {
            Picker("Sort", selection: Bindable(model).albumSortOrder) {
                ForEach(AlbumSortOrder.allCases) { order in
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
        .accessibilityLabel("Sort")
    }

    private var artistSortMenu: some View {
        Menu {
            Picker("Sort", selection: Bindable(model).artistSortOrder) {
                ForEach(ArtistSortOrder.allCases) { order in
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
        .accessibilityLabel("Sort")
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
                    Label("Import from Desktop", systemImage: "arrow.down.doc")
                }
            }
            Button {
                playlistEditMode = playlistEditMode == .active ? .inactive : .active
            } label: {
                Label(
                    playlistEditMode == .active ? "End Reordering" : "Reorder",
                    systemImage: "arrow.up.arrow.down"
                )
            }
            Button {
                newPlaylistName = ""
                showNewPlaylistAlert = true
            } label: {
                Label("New Playlist", systemImage: "plus")
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
            "No Downloaded Songs",
            systemImage: "music.note.list",
            description: Text("Download songs from the remote library.")
        )
    }

    @ViewBuilder
    private var playlistContent: some View {
        if model.playlists.isEmpty {
            ContentUnavailableView {
                Label("No Playlists Yet", systemImage: "music.note.list")
            } description: {
                Text("Create one with + or import from desktop.")
            } actions: {
                if model.serverConfig.isConfigured {
                    Button {
                        showDesktopPlaylistImport = true
                    } label: {
                        Label("Import Desktop Playlist", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        } else if searchedPlaylists.isEmpty {
            Text("No Matching Playlists")
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
                                    Text(String(format: String(localized: "%ld Songs"), pl.songIds.count))
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
                                Label("Reorder", systemImage: "arrow.up.arrow.down")
                            }
                            WatchTransferBulkMenuItem(
                                title: "Transfer Playlist to Apple Watch",
                                songs: model.resolvedSongs(for: pl)
                            )
                            Button(role: .destructive) {
                                try? model.deletePlaylist(id: pl.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
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
                            Text(String(format: String(localized: "%@ · %ld Songs"), album.displayArtist, album.songs.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        WatchTransferBulkMenuItem(
                            title: "Transfer Album to Apple Watch",
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
                        Label("Remove from Library", systemImage: "trash")
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
            Text("No Matching Artists")
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
                                Text(String(format: String(localized: "%ld Albums · %ld Songs"), artist.albums.count, artist.songs.count))
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
                            title: "Transfer Artist's Songs to Apple Watch",
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
