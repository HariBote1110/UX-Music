import SwiftUI
import AVFoundation

struct NowPlayingView: View {
    @EnvironmentObject private var player: AudioPlayerService

    var body: some View {
        VStack(spacing: 8) {
            // Artwork placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.2))
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 60, height: 60)

            // Metadata
            VStack(spacing: 2) {
                Text(player.currentSong?.displayTitle ?? "Not Playing")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(player.currentSong?.displayArtist ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Progress
            if let song = player.currentSong {
                VStack(spacing: 2) {
                    ProgressView(value: player.position, total: song.duration)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                    HStack {
                        Text(formatTime(player.position))
                        Spacer()
                        Text(song.formattedDuration)
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
            }

            // Controls
            HStack(spacing: 16) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .focusable()
        .digitalCrownRotation(
            $player.volume,
            from: 0,
            through: 1,
            by: 0.05,
            sensitivity: .medium
        )
        .navigationTitle("Now Playing")
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
