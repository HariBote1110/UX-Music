import SwiftUI

private enum RemoteViewMode: String, CaseIterable {
    case albums, songs
}

struct RemoteLibraryScreen: View {
    @Environment(AppModel.self) private var model
    @State private var viewMode: RemoteViewMode = .albums
    @State private var query = ""
    @State private var path = NavigationPath()
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
                        Text("Songs").tag(RemoteViewMode.songs)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await model.refreshLibrary()
                            await model.refreshLoudnessOnly()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh library")
                }
            }
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(album: album)
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
                if filtered.isEmpty {
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

    private func remoteAlbumsGrid(songs: [Song]) -> some View {
        let albums = Album.fromSongs(songs)
        return ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(albums) { album in
                    Button {
                        path.append(album)
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
