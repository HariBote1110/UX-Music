import SwiftUI

/// Song list received from the iPhone. Tapping a row starts playback and switches to the
/// Now Playing page (see `WatchRootView`'s paged `TabView`); swipe-to-delete removes the song and
/// its audio file. The currently-playing song is marked with a small speaker glyph.
struct WatchSongListView: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    @EnvironmentObject private var player: WatchAudioPlayerService
    @Binding var selectedPage: WatchPage

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
                        Button {
                            player.play(meta, queue: library.songs)
                            selectedPage = .nowPlaying
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meta.displayTitle)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(meta.displayArtist)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if player.currentSong?.id == meta.id {
                                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                        .foregroundStyle(.blue)
                                        .font(.caption)
                                }
                            }
                        }
                        .buttonStyle(.plain)
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
    WatchSongListView(selectedPage: .constant(.library))
        .environmentObject(WatchLocalLibrary())
        .environmentObject(WatchAudioPlayerService(library: WatchLocalLibrary()))
}
