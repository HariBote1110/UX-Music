import SwiftUI
import WatchConnectivity

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlistId: String

    @State private var showAddSongs = false
    @State private var showRename = false
    @State private var renameText = ""

    private var playlist: Playlist? {
        model.playlists.first { $0.id == playlistId }
    }

    private var songs: [Song] {
        guard let pl = playlist else { return [] }
        return model.resolvedSongs(for: pl)
    }

    private var canShowWatchTransferMenu: Bool {
        WatchTransferMenuPolicy.canShowMenu(
            isWatchConnectivitySupported: WCSession.isSupported(),
            isPaired: model.watchTransferBridge.isPaired
        )
    }

    var body: some View {
        LibraryBottomBleed { bottomInset in
            listBody
                .contentMargins(.bottom, bottomInset, for: .scrollContent)
        }
        .background(Color.black)
        .navigationTitle(playlist?.name ?? String(localized: "Playlist"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar { detailToolbar }
        .sheet(isPresented: $showAddSongs) {
            AddSongsToPlaylistSheet(playlistId: playlistId)
                .environment(model)
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                try? model.renamePlaylist(id: playlistId, newName: renameText)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name for this playlist.")
        }
    }

    @ViewBuilder
    private var listBody: some View {
        Group {
            if playlist == nil {
                ContentUnavailableView(
                    "Playlist Unavailable",
                    systemImage: "music.note.list",
                    description: Text("This playlist was deleted or is no longer available.")
                )
            } else {
                List {
                    ForEach(songs) { song in
                        SongRowView(
                            song: song,
                            artworkId: song.artworkId,
                            artworkURL: model.artworkURL(for: song.artworkId),
                            onTap: {
                                play(song)
                            }
                        )
                        .modifier(LibraryListRowStyle())
                        .contextMenu {
                            SongQueueMenuItems(song: song.withPath(model.downloadManager.localPathString(songId: song.id)))
                            WatchTransferSongMenuItem(song: song)
                            Button(role: .destructive) {
                                try? model.removeSongsFromPlaylist(playlistId: playlistId, songIds: [song.id])
                            } label: {
                                Label("Remove from Playlist", systemImage: "minus.circle")
                            }
                        }
                    }
                    .onMove { source, destination in
                        try? model.moveSongs(inPlaylistId: playlistId, fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        if playlist != nil {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    EditButton()
                    if canShowWatchTransferMenu {
                        Menu {
                            WatchTransferBulkMenuItem(
                                title: "Transfer Playlist to Apple Watch",
                                songs: songs
                            )
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    Button {
                        showAddSongs = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Songs")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Rename") {
                    renameText = playlist?.name ?? ""
                    showRename = true
                }
            }
        }
    }

    private func play(_ song: Song) {
        let downloaded = songs.filter { model.isSongDownloaded(songId: $0.id) }
        let localSong = song.withPath(model.downloadManager.localPathString(songId: song.id))
        let queue = downloaded.map { $0.withPath(model.downloadManager.localPathString(songId: $0.id)) }
        Task {
            await model.player.play(localSong, newQueue: queue)
        }
    }
}

// MARK: - Add songs

private struct AddSongsToPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let playlistId: String

    private var playlist: Playlist? {
        model.playlists.first { $0.id == playlistId }
    }

    private var candidates: [Song] {
        let inPlaylist = Set(playlist?.songIds ?? [])
        return model.downloadedSongsEligibleForPlaylist(excludingPlaylistSongIds: inPlaylist)
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("All downloaded songs are already in this playlist.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { song in
                        Button {
                            try? model.addSongsToPlaylist(playlistId: playlistId, songIds: [song.id])
                            if candidates.count <= 1 {
                                dismiss()
                            }
                        } label: {
                            SongRowView(
                                song: song,
                                artworkId: song.artworkId,
                                artworkURL: model.artworkURL(for: song.artworkId),
                                onTap: nil,
                                trailing: { EmptyView() }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
