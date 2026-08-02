import SwiftUI

/// Song list received from the iPhone. Tapping a row starts playback and pushes
/// `WatchNowPlayingView`; swipe-to-delete removes the song and its audio file.
struct WatchSongListView: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    @EnvironmentObject private var player: WatchAudioPlayerService

    var body: some View {
        NavigationStack {
            Group {
                if library.songs.isEmpty {
                    Text("No songs yet.\nTransfer from the iPhone app.")
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    List(library.songs) { meta in
                        NavigationLink {
                            WatchNowPlayingView()
                                .onAppear { player.play(meta, queue: library.songs) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meta.displayTitle)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(meta.displayArtist)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                library.removeSong(id: meta.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
        }
    }
}

#Preview {
    WatchSongListView()
        .environmentObject(WatchLocalLibrary())
        .environmentObject(WatchAudioPlayerService(library: WatchLocalLibrary()))
}
