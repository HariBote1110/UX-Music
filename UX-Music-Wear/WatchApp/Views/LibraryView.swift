import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LocalLibrary
    @EnvironmentObject private var player: AudioPlayerService

    var body: some View {
        NavigationStack {
            Group {
                if library.songs.isEmpty {
                    Text("No songs yet.\nSync from the iPhone app.")
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    List(library.songs, id: \.id) { meta in
                        Button {
                            player.play(meta, queue: library.songs)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meta.title.isEmpty ? meta.id : meta.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(meta.artist.isEmpty ? "Unknown Artist" : meta.artist)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
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
