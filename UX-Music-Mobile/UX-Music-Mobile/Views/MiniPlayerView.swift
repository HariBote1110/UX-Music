import SwiftUI

struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let song = model.player.currentSong {
                HStack(spacing: 12) {
                    Button {
                        model.isNowPlayingSheetPresented = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.displayTitle)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(song.displayArtist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        model.player.togglePlayPause()
                    } label: {
                        Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .frame(maxWidth: .infinity)
            }
        }
    }
}
