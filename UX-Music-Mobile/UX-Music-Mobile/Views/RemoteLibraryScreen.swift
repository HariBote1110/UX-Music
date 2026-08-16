import SwiftUI

private enum RemoteViewMode: Int, CaseIterable {
    case albums, playlists, songs

    var title: String {
        switch self {
        case .albums: return String(localized: "Albums")
        case .playlists: return String(localized: "Playlists")
        case .songs: return String(localized: "Songs")
        }
    }
}

private enum RemoteLibraryNav: Hashable {
    case album(Album)
    case playlist(RemoteDesktopPlaylist)
}

struct RemoteLibraryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewMode: RemoteViewMode = .albums
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var showDesktopPlaylistImport = false
    @State private var remotePlaylistRows: [RemoteDesktopPlaylist] = []
    @State private var remotePlaylistsError: String?
    @State private var isLoadingRemotePlaylists = false
    /// Avoid refetching on every `NavigationStack` pop; reset when this screen is recreated (e.g. changing tabs).
    @State private var didScheduleRemoteLoad = false
    @State private var showAddYouTubeLink = false

    private var viewModeIndex: Binding<Int> {
        Binding(
            get: { viewMode.rawValue },
            set: { newValue in
                if let mode = RemoteViewMode(rawValue: newValue) { viewMode = mode }
            }
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            // See `LibraryBottomBleed`: without it the grids/lists stop at the tab bar's top edge
            // instead of scrolling under it. Mirrors `LocalLibraryScreen`: the paged `TabView`
            // (inside `libraryBody`) insets its own pages by the safe area, so the pages are let
            // through to the screen's bottom edge here and that inset is re-applied per page as
            // scroll content margin via `page(bottomInset:)`.
            //
            // Rows on this screen use context menus rather than `swipeActions`, so there is no
            // gesture conflict with the page swipe to guard against (see `LocalLibraryScreen`'s
            // note on why `swipeActions` was removed there).
            LibraryBottomBleed { bottomInset in
                VStack(spacing: 0) {
                    LibrarySegmentedHeader(
                        segments: RemoteViewMode.allCases.map(\.title),
                        selectedIndex: viewModeIndex
                    )
                    LibrarySearchRow(query: $query) { remoteActions }
                    if let status = model.bulkDownloadStatus {
                        BulkDownloadStatusBanner(status: status)
                    }
                    libraryBody(bottomInset: bottomInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showDesktopPlaylistImport) {
                DesktopPlaylistImportView(isPresented: $showDesktopPlaylistImport)
                    .environment(model)
            }
            .sheet(isPresented: $showAddYouTubeLink) {
                AddYouTubeLinkSheet(isPresented: $showAddYouTubeLink)
                    .environment(model)
            }
            .navigationDestination(for: RemoteLibraryNav.self) { route in
                switch route {
                case .album(let album):
                    AlbumDetailView(album: album)
                case .playlist(let pl):
                    RemotePlaylistDetailView(playlist: pl)
                }
            }
            .task(id: viewMode) {
                guard viewMode == .playlists else { return }
                guard case .loaded = model.libraryState else { return }
                await loadRemotePlaylists()
            }
            .onChange(of: model.libraryState) { _, newState in
                guard viewMode == .playlists, case .loaded = newState else { return }
                Task { await loadRemotePlaylists() }
            }
            // `onAppear` is reliable when the Remote tab is mounted lazily; `.task` on `NavigationStack`
            // can fail to run or cancel in a way that leaves `libraryState` stuck.
            .onAppear {
                guard !didScheduleRemoteLoad else { return }
                didScheduleRemoteLoad = true
                if case .loaded = model.libraryState {
                    Task { await model.refreshLoudnessOnly() }
                    return
                }
                Task {
                    await model.refreshLibrary()
                    await model.refreshLoudnessOnly()
                }
            }
        }
    }

    private var remoteActions: some View {
        HStack(spacing: 8) {
            if model.serverConfig.isConfigured {
                Button {
                    showDesktopPlaylistImport = true
                } label: {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
                .modifier(LibraryHeaderGlassButtonStyle())
                .accessibilityLabel("Import Desktop Playlist")
            }
            Button {
                Task {
                    await model.refreshLibrary()
                    await model.refreshLoudnessOnly()
                    if viewMode == .playlists {
                        await loadRemotePlaylists()
                    }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .modifier(LibraryHeaderGlassButtonStyle())
            .accessibilityLabel("Refresh Library")

            if model.serverConfig.isConfigured {
                Menu {
                    Button {
                        showAddYouTubeLink = true
                    } label: {
                        Label("Add YouTube URL", systemImage: "play.rectangle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
                .modifier(LibraryHeaderGlassButtonStyle())
                .accessibilityLabel("More Actions")
            }
        }
    }

    /// Every page fills the paged `TabView` so the three segments are the same height and the
    /// swipe gesture is live over the whole area, not just where a page happens to have content.
    /// `bottomInset` is the tab bar's safe area, re-applied to the page's scroll content because
    /// the pages themselves extend past it (see `body`). Mirrors
    /// `LocalLibraryScreen.page(bottomInset:)`.
    private func page<Content: View>(
        bottomInset: CGFloat,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
    }

    @ViewBuilder
    private func libraryBody(bottomInset: CGFloat) -> some View {
        switch model.libraryState {
        case .idle:
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            errorView
        case .loaded(let songs):
            VStack(spacing: 0) {
                if let err = model.downloadError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Button("Close") {
                            model.downloadError = nil
                        }
                        .font(.footnote)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.15))
                }
                TabView(selection: $viewMode) {
                    page(bottomInset: bottomInset) { albumsPane(songs: songs) }
                        .tag(RemoteViewMode.albums)
                    page(bottomInset: bottomInset) { playlistsPane(songs: songs) }
                        .tag(RemoteViewMode.playlists)
                    page(bottomInset: bottomInset) { songsPane(songs: songs) }
                        .tag(RemoteViewMode.songs)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func albumsPane(songs: [Song]) -> some View {
        let albums = filterAlbums(Album.fromSongs(songs))
        if albums.isEmpty {
            Text(songs.isEmpty ? "No Songs on Server" : "No Matching Songs")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            remoteAlbumsGrid(albums: albums)
        }
    }

    private func playlistsPane(songs: [Song]) -> some View {
        remotePlaylistsPane(librarySongs: songs)
    }

    @ViewBuilder
    private func songsPane(songs: [Song]) -> some View {
        let filtered = SongSearchFilter.filter(songs, query: query)
        if filtered.isEmpty {
            Text(songs.isEmpty ? "No Songs on Server" : "No Matching Songs")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            remoteSongsList(songs: filtered)
        }
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Failed to Load Library")
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await model.refreshLibrary() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Keeps an album entry (with all of its tracks, not just the matching ones) when any of its
    /// songs match the current search query — album membership shouldn't fragment mid-scroll just
    /// because one track's tag didn't match.
    private func filterAlbums(_ albums: [Album]) -> [Album] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return albums }
        return albums.filter { !SongSearchFilter.filter($0.songs, query: query).isEmpty }
    }

    private func loadRemotePlaylists() async {
        guard model.serverConfig.isConfigured else {
            await MainActor.run {
                remotePlaylistRows = []
                remotePlaylistsError = nil
                isLoadingRemotePlaylists = false
            }
            return
        }
        await MainActor.run {
            isLoadingRemotePlaylists = true
            remotePlaylistsError = nil
        }
        do {
            let rows = try await model.fetchDesktopPlaylistsPreview()
            await MainActor.run {
                remotePlaylistRows = rows
                isLoadingRemotePlaylists = false
            }
        } catch {
            await MainActor.run {
                remotePlaylistsError = error.localizedDescription
                isLoadingRemotePlaylists = false
            }
        }
    }

    private func resolveSongs(for playlist: RemoteDesktopPlaylist, library: [Song]) -> [Song] {
        var byId: [String: Song] = [:]
        for s in library { byId[s.id] = s }
        return playlist.songIds.compactMap { byId[$0] }
    }

    private func filterPlaylists(_ rows: [RemoteDesktopPlaylist]) -> [RemoteDesktopPlaylist] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.name.lowercased().contains(q) }
    }

    @ViewBuilder
    private func remotePlaylistsPane(librarySongs: [Song]) -> some View {
        if !model.serverConfig.isConfigured {
            Text("Connect to desktop in Settings to browse and download playlists.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoadingRemotePlaylists, remotePlaylistRows.isEmpty, remotePlaylistsError == nil {
            ProgressView("Loading Playlists…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = remotePlaylistsError {
            VStack(spacing: 12) {
                Text("Couldn't Load Playlists")
                    .font(.body.weight(.semibold))
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await loadRemotePlaylists() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let filteredRows = filterPlaylists(remotePlaylistRows)
            if filteredRows.isEmpty {
                Text(query.isEmpty ? "No Playlists on Desktop" : "No Matching Playlists")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                remotePlaylistsGrid(rows: filteredRows, librarySongs: librarySongs)
            }
        }
    }

    private func remotePlaylistsGrid(rows: [RemoteDesktopPlaylist], librarySongs: [Song]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, pl in
                    let songsInPl = resolveSongs(for: pl, library: librarySongs)
                    let art = songsInPl.first { !$0.artworkId.isEmpty }?.artworkId ?? ""
                    let count = songsInPl.count
                    Button {
                        path.append(RemoteLibraryNav.playlist(pl))
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            GeometryReader { geo in
                                let side = geo.size.width
                                ZStack {
                                    if art.isEmpty {
                                        Color(white: 0.14)
                                        Image(systemName: "music.note.list")
                                            .font(.system(size: side * 0.28, weight: .light))
                                            .foregroundStyle(.white.opacity(0.25))
                                    } else {
                                        ArtworkImageView(
                                            artworkId: art,
                                            urlString: model.artworkURL(for: art),
                                            cornerRadius: 10,
                                            size: side
                                        )
                                    }
                                }
                                .frame(width: side, height: side)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .aspectRatio(1, contentMode: .fit)
                            Text(pl.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Text(String(format: String(localized: "%ld Songs"), count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if model.playlistSongsContainUndownloaded(songsInPl) {
                            Button {
                                Task { await model.downloadPlaylistSongs(songsInPl) }
                            } label: {
                                Label("Download Playlist", systemImage: "arrow.down.circle")
                            }
                        }
                        WatchTransferBulkMenuItem(
                            title: "Transfer Playlist to Apple Watch",
                            songs: songsInPl
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func remoteAlbumsGrid(albums: [Album]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(albums) { album in
                    Button {
                        path.append(RemoteLibraryNav.album(album))
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            GeometryReader { geo in
                                let side = geo.size.width
                                ArtworkImageView(
                                    artworkId: album.artworkId,
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
                            Text(album.displayArtist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if model.albumHasTracksToDownload(album) {
                            Button {
                                Task { await model.downloadAlbum(album) }
                            } label: {
                                Label("Download Album", systemImage: "arrow.down.circle")
                            }
                        }
                        WatchTransferBulkMenuItem(
                            title: "Transfer Album to Apple Watch",
                            songs: album.songs
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func remoteSongsList(songs: [Song]) -> some View {
        // Mirrors `LocalLibraryScreen`'s rule (task 1): only draw album-run connectors while the
        // shared `librarySortOrder` is `.album` — Remote has no sort control of its own, but its
        // song order comes straight from the server in album order, so this stays meaningful
        // whenever Local hasn't been switched to title/artist/duration.
        let groupPositions: [AlbumGroupPosition]? =
            model.librarySortOrder == .album ? AlbumGrouping.positions(for: songs) : nil
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRowView(
                        song: song,
                        artworkId: song.artworkId,
                        artworkURL: model.artworkURL(for: song.artworkId),
                        albumGroupPosition: groupPositions?[index],
                        onTap: rowTap(for: song, in: songs),
                        trailing: {
                            SongRowDownloadTrailing(song: song)
                        }
                    )
                    .padding(.horizontal, SongRowMetrics.horizontalInset)
                    .contextMenu {
                        if song.isYouTube {
                            if model.isLibrarySongMember(songId: song.id) {
                                Button(role: .destructive) {
                                    model.removeYouTubeSongFromLibrary(songId: song.id)
                                } label: {
                                    Label("Remove from Library", systemImage: "minus.circle")
                                }
                            } else {
                                Button {
                                    model.addYouTubeSongToLibrary(song)
                                } label: {
                                    Label("Add to Library", systemImage: "plus.circle")
                                }
                            }
                        }
                        WatchTransferSongMenuItem(song: song)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func rowTap(for song: Song, in list: [Song]) -> (() -> Void)? {
        switch song.rowTapAction(isDownloaded: model.isSongDownloaded(songId: song.id)) {
        case .openYouTubePlayer: return { playYouTube(song) }
        case .playDownloaded: return { playDownloaded(song, in: list) }
        case .none: return nil
        }
    }

    /// Plays a YouTube library song as a normal single-song queue, exactly like tapping any local
    /// song — the mini player picks it up and expands into `NowPlayingView` on tap, same as any
    /// other track. YouTube songs get no dedicated player screen any more (see
    /// `progress/mobile-youtube-embed.md`).
    private func playYouTube(_ song: Song) {
        Task {
            await model.player.play(song, newQueue: [song])
        }
    }

    private func playDownloaded(_ song: Song, in list: [Song]) {
        let downloaded = list.filter { model.isSongDownloaded(songId: $0.id) }
        let localSong = song.withPath(model.downloadManager.localPathString(songId: song.id))
        let queue = downloaded.map { $0.withPath(model.downloadManager.localPathString(songId: $0.id)) }
        Task {
            await model.player.play(localSong, newQueue: queue)
        }
    }
}
