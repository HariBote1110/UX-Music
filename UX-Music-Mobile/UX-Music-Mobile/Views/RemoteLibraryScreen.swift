import SwiftUI

private enum RemoteViewMode: Int, CaseIterable {
    case albums, playlists, songs

    var title: String {
        switch self {
        case .albums: return "アルバム"
        case .playlists: return "プレイリスト"
        case .songs: return "曲"
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
            VStack(spacing: 0) {
                LibrarySegmentedHeader(
                    segments: RemoteViewMode.allCases.map(\.title),
                    selectedIndex: viewModeIndex
                ) {
                    remoteActions
                }
                searchField
                libraryBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .accessibilityLabel("デスクトップのプレイリストを取り込む")
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
            .accessibilityLabel("ライブラリを更新")

            if model.serverConfig.isConfigured {
                Menu {
                    Button {
                        showAddYouTubeLink = true
                    } label: {
                        Label("YouTube の URL を追加", systemImage: "play.rectangle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                }
                .modifier(LibraryHeaderGlassButtonStyle())
                .accessibilityLabel("その他の操作")
            }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("曲・アーティスト・アルバムを検索", text: $query)
                .textFieldStyle(.plain)
        }
        .padding(10)
        .background(Color(red: 0.17, green: 0.17, blue: 0.18))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var libraryBody: some View {
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
                        Button("閉じる") {
                            model.downloadError = nil
                        }
                        .font(.footnote)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.15))
                }
                if viewMode == .playlists {
                    remotePlaylistsPane(librarySongs: songs)
                } else if viewMode == .albums {
                    let albums = filterAlbums(Album.fromSongs(songs))
                    if albums.isEmpty {
                        Text(songs.isEmpty ? "サーバーに曲がありません" : "一致する曲がありません")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        remoteAlbumsGrid(albums: albums)
                    }
                } else {
                    let filtered = SongSearchFilter.filter(songs, query: query)
                    if filtered.isEmpty {
                        Text(songs.isEmpty ? "サーバーに曲がありません" : "一致する曲がありません")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        remoteSongsList(songs: filtered)
                    }
                }
            }
        }
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("ライブラリの読み込みに失敗しました")
                .foregroundStyle(.secondary)
            Button("再試行") {
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
            Text("設定でデスクトップに接続すると、プレイリストを表示してダウンロードできます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLoadingRemotePlaylists, remotePlaylistRows.isEmpty, remotePlaylistsError == nil {
            ProgressView("プレイリストを読み込み中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = remotePlaylistsError {
            VStack(spacing: 12) {
                Text("プレイリストを取得できませんでした")
                    .font(.body.weight(.semibold))
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("再試行") {
                    Task { await loadRemotePlaylists() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let filteredRows = filterPlaylists(remotePlaylistRows)
            if filteredRows.isEmpty {
                Text(query.isEmpty ? "デスクトップにプレイリストがありません" : "一致するプレイリストがありません")
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
                            Text("\(count) 曲")
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
                                Label("プレイリストをダウンロード", systemImage: "arrow.down.circle")
                            }
                        }
                        WatchTransferBulkMenuItem(
                            title: "プレイリストを Apple Watch に転送",
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
                                Label("アルバムをダウンロード", systemImage: "arrow.down.circle")
                            }
                        }
                        WatchTransferBulkMenuItem(
                            title: "アルバムを Apple Watch に転送",
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contextMenu {
                        if song.isYouTube {
                            if model.isLibrarySongMember(songId: song.id) {
                                Button(role: .destructive) {
                                    model.removeYouTubeSongFromLibrary(songId: song.id)
                                } label: {
                                    Label("ライブラリから削除", systemImage: "minus.circle")
                                }
                            } else {
                                Button {
                                    model.addYouTubeSongToLibrary(song)
                                } label: {
                                    Label("ライブラリに追加", systemImage: "plus.circle")
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
