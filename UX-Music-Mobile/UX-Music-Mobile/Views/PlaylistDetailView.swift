import SwiftUI

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

    var body: some View {
        Group {
            if playlist == nil {
                ContentUnavailableView(
                    "Playlist unavailable",
                    systemImage: "music.note.list",
                    description: Text("This playlist was removed or is no longer available.")
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
                        .listRowBackground(Color(red: 0.07, green: 0.07, blue: 0.08))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                try? model.removeSongsFromPlaylist(playlistId: playlistId, songIds: [song.id])
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
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
        .background(Color.black)
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if playlist != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        EditButton()
                        Button {
                            showAddSongs = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add songs")
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
        .sheet(isPresented: $showAddSongs) {
            AddSongsToPlaylistSheet(playlistId: playlistId)
                .environment(model)
        }
        .alert("Rename playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                try? model.renamePlaylist(id: playlistId, newName: renameText)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name for this playlist.")
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
            .navigationTitle("Add songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
