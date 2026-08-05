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
        Group {
            if playlist == nil {
                ContentUnavailableView(
                    "プレイリストを利用できません",
                    systemImage: "music.note.list",
                    description: Text("このプレイリストは削除されたか、利用できなくなりました。")
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
                        .contextMenu {
                            WatchTransferSongMenuItem(song: song)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                try? model.removeSongsFromPlaylist(playlistId: playlistId, songIds: [song.id])
                            } label: {
                                Label("削除", systemImage: "minus.circle")
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
        .navigationTitle(playlist?.name ?? "プレイリスト")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if playlist != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        EditButton()
                        if canShowWatchTransferMenu {
                            Menu {
                                WatchTransferBulkMenuItem(
                                    title: "プレイリストを Apple Watch に転送",
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
                        .accessibilityLabel("曲を追加")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("名前を変更") {
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
        .alert("プレイリスト名を変更", isPresented: $showRename) {
            TextField("名前", text: $renameText)
            Button("保存") {
                try? model.renamePlaylist(id: playlistId, newName: renameText)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("このプレイリストの新しい名前を入力してください。")
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
                    Text("ダウンロード済みの曲はすべてこのプレイリストに追加済みです。")
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
            .navigationTitle("曲を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
