import SwiftUI

private enum RemoteViewMode: String, CaseIterable {
    case albums, playlists, songs
}

private enum RemoteLibraryNav: Hashable {
    case album(Album)
    case playlist(WearDesktopPlaylist)
}

struct RemoteLibraryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewMode: RemoteViewMode = .albums
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var showDesktopPlaylistImport = false
    @State private var remotePlaylistRows: [WearDesktopPlaylist] = []
    @State private var remotePlaylistsError: String?
    @State private var isLoadingRemotePlaylists = false
    /// Avoid refetching on every `NavigationStack` pop; reset when this screen is recreated (e.g. changing tabs).
    @State private var didScheduleRemoteLoad = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                searchField
                libraryBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("Remote Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $viewMode) {
                        Text("Albums").tag(RemoteViewMode.albums)
                        Text("Playlists").tag(RemoteViewMode.playlists)
                        Text("Songs").tag(RemoteViewMode.songs)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if model.serverConfig.isConfigured {
                            Button {
                                showDesktopPlaylistImport = true
                            } label: {
                                Image(systemName: "arrow.down.doc")
                            }
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
                        }
                        .accessibilityLabel("Refresh library")
                    }
                }
            }
            .sheet(isPresented: $showDesktopPlaylistImport) {
                DesktopPlaylistImportView(isPresented: $showDesktopPlaylistImport)
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

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search…", text: $query)
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
            let filtered = filter(songs)
            VStack(spacing: 0) {
                if let err = model.downloadError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Button("Dismiss") {
                            model.downloadError = nil
                        }
                        .font(.footnote)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.15))
                }
                if viewMode == .playlists {
                    remotePlaylistsPane(librarySongs: songs)
                } else if filtered.isEmpty {
                    Text(songs.isEmpty ? "No songs on server" : "No matching songs")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewMode == .albums {
                    remoteAlbumsGrid(songs: filtered)
                } else {
                    remoteSongsList(songs: filtered)
                }
            }
        }
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Failed to load library")
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await model.refreshLibrary() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filter(_ songs: [Song]) -> [Song] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return songs }
        return songs.filter {
            $0.title.lowercased().contains(q)
                || $0.artist.lowercased().contains(q)
                || $0.album.lowercased().contains(q)
        }
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

    private func resolveSongs(for playlist: WearDesktopPlaylist, library: [Song]) -> [Song] {
        var byId: [String: Song] = [:]
        for s in library { byId[s.id] = s }
        return playlist.songIds.compactMap { byId[$0] }
    }

    private func filterPlaylists(_ rows: [WearDesktopPlaylist]) -> [WearDesktopPlaylist] {
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

    private func remotePlaylistsGrid(rows: [WearDesktopPlaylist], librarySongs: [Song]) -> some View {
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
                            Text("\(count) songs")
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
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func remoteAlbumsGrid(songs: [Song]) -> some View {
        let albums = Album.fromSongs(songs)
        return ScrollView {
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
                                Label("Download album", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func remoteSongsList(songs: [Song]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(songs) { song in
                    SongRowView(
                        song: song,
                        artworkId: song.artworkId,
                        artworkURL: model.artworkURL(for: song.artworkId),
                        onTap: model.isSongDownloaded(songId: song.id)
                            ? { playDownloaded(song, in: songs) }
                            : nil,
                        trailing: {
                            downloadTrailing(for: song)
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func downloadTrailing(for song: Song) -> some View {
        if model.isSongDownloaded(songId: song.id) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 20))
        } else if let p = model.downloadProgress[song.id] {
            Group {
                if p > 0 {
                    ProgressView(value: p, total: 1)
                } else {
                    ProgressView()
                }
            }
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

    private func playDownloaded(_ song: Song, in list: [Song]) {
        let downloaded = list.filter { model.isSongDownloaded(songId: $0.id) }
        let localSong = song.withPath(model.downloadManager.localPathString(songId: song.id))
        let queue = downloaded.map { $0.withPath(model.downloadManager.localPathString(songId: $0.id)) }
        Task {
            await model.player.play(localSong, newQueue: queue)
        }
    }
}
