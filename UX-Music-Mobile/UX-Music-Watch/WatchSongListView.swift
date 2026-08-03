import SwiftUI
import UIKit

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
                                WatchArtworkThumbnail(meta: meta)
                                    .frame(width: 28, height: 28)
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

/// Small library-row thumbnail: the received-artwork JPEG if present, otherwise a generic note
/// glyph placeholder. Kept as its own view (rather than inline in the `List`) so each row only
/// re-reads its own artwork file, not the whole list's.
private struct WatchArtworkThumbnail: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    let meta: WatchTransferMeta

    var body: some View {
        ZStack {
            if let url = library.artworkFileURLIfPresent(for: meta), let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                Image(systemName: "music.note")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    WatchSongListView(selectedPage: .constant(.library))
        .environmentObject(WatchLocalLibrary())
        .environmentObject(WatchAudioPlayerService(library: WatchLocalLibrary()))
}
