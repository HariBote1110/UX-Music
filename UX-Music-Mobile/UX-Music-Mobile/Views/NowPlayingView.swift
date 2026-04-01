import SwiftUI

private let nowPlayingFallbackAccent = Color(red: 0.45, green: 0.82, blue: 1.0)

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let song = model.player.currentSong {
                    NowPlayingPlayingShell(
                        song: song,
                        artworkURLString: model.artworkURL(for: song.artworkId)
                    )
                } else {
                    NowPlayingEmptyChrome()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Playing shell (isolates high-frequency player updates in child views)

private struct NowPlayingPlayingShell: View {
    let song: Song
    let artworkURLString: String

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var palette: ArtworkPlaybackPalette?

    private var accent: Color {
        palette?.accentColor ?? nowPlayingFallbackAccent
    }

    var body: some View {
        ZStack {
            NowPlayingAmbientBackground(palette: palette)
                .animation(.easeInOut(duration: 0.5), value: palette)

            VStack(spacing: 0) {
                Spacer(minLength: horizontalSizeClass == .regular ? 40 : 16)

                NowPlayingArtworkBlock(urlString: artworkURLString, accent: accent)
                    .padding(.horizontal, 28)

                Spacer(minLength: 28)

                VStack(spacing: 10) {
                    Text(song.displayTitle)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(.white)

                    Text(song.displayArtist)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)

                    if !song.album.isEmpty {
                        Text(song.displayAlbum)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 28)

                Spacer(minLength: 24)

                NowPlayingProgressSection(accent: accent)
                    .padding(.horizontal, 24)

                Spacer(minLength: 20)

                NowPlayingTransportSection(accent: accent)
                    .padding(.bottom, 8)

                Spacer(minLength: horizontalSizeClass == .regular ? 48 : 24)
            }
        }
        .task(id: artworkURLString) {
            guard let url = URL(string: artworkURLString), !artworkURLString.isEmpty else {
                palette = nil
                return
            }
            palette = await ArtworkPaletteExtractor.palette(forArtworkURL: url)
        }
    }
}

// MARK: - Progress (only this subtree observes position / duration)

private struct NowPlayingProgressSection: View {
    @Environment(AppModel.self) private var model
    let accent: Color

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        let duration = max(model.player.durationSeconds, 0.001)
        VStack(alignment: .leading, spacing: 10) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : model.player.positionSeconds },
                    set: { newValue in
                        scrubValue = newValue
                    }
                ),
                in: 0 ... duration,
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        scrubValue = model.player.positionSeconds
                    } else {
                        isScrubbing = false
                        Task { await model.player.seek(to: scrubValue) }
                    }
                }
            )
            .tint(accent)
            .controlSize(.small)

            HStack {
                Text(formatTime(isScrubbing ? scrubValue : model.player.positionSeconds))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let m = Int(safe) / 60
        let s = Int(safe) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

// MARK: - Transport (only this subtree observes isPlaying)

private struct NowPlayingTransportSection: View {
    @Environment(AppModel.self) private var model
    let accent: Color

    var body: some View {
        HStack(spacing: 44) {
            transportIconButton(systemName: "backward.fill", size: 22) {
                Task { await model.player.previous() }
            }
            .accessibilityLabel("Previous track")

            Button {
                model.player.togglePlayPause()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 80, height: 80)
                    .background(
                        Circle()
                            .fill(.white)
                            .shadow(color: accent.opacity(0.35), radius: 24, y: 10)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")

            transportIconButton(systemName: "forward.fill", size: 22) {
                Task { await model.player.next() }
            }
            .accessibilityLabel("Next track")
        }
    }

    private func transportIconButton(systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty state

private struct NowPlayingEmptyChrome: View {
    var body: some View {
        ZStack {
            NowPlayingAmbientBackground(palette: nil)
            VStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
                    .symbolRenderingMode(.hierarchical)
                Text("Nothing playing")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Start playback from your library.")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
    }
}

// MARK: - Background

private struct NowPlayingAmbientBackground: View {
    var palette: ArtworkPlaybackPalette?

    var body: some View {
        ZStack {
            if let p = palette {
                LinearGradient(
                    colors: [
                        p.topColor,
                        Color.black,
                        p.bottomColor,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [p.accentColor.opacity(0.32), .clear],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 340
                )
                .blendMode(.plusLighter)

                RadialGradient(
                    colors: [p.bottomColor.opacity(0.55), .clear],
                    center: .bottomLeading,
                    startRadius: 10,
                    endRadius: 300
                )
                .blendMode(.plusLighter)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.05, blue: 0.12),
                        Color.black,
                        Color(red: 0.04, green: 0.06, blue: 0.09),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [nowPlayingFallbackAccent.opacity(0.22), .clear],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 320
                )
                .blendMode(.plusLighter)

                RadialGradient(
                    colors: [Color.purple.opacity(0.12), .clear],
                    center: .bottomLeading,
                    startRadius: 10,
                    endRadius: 280
                )
                .blendMode(.plusLighter)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Artwork

private struct NowPlayingArtworkBlock: View {
    let urlString: String
    let accent: Color

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 340)
            .overlay {
                artworkFill
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 32, y: 18)
            .shadow(color: accent.opacity(0.15), radius: 40, y: 12)
    }

    @ViewBuilder
    private var artworkFill: some View {
        if urlString.isEmpty {
            placeholder
        } else if let u = URL(string: urlString) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    ZStack {
                        placeholder
                        ProgressView()
                            .tint(.white.opacity(0.6))
                    }
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(white: 0.14),
                    Color(white: 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.22))
        }
    }
}
