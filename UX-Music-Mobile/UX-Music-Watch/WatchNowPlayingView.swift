import SwiftUI
import UIKit

/// Now Playing page: always reachable via the paged `TabView` in `WatchRootView`, regardless of
/// what is selected on the Library page. The cached artwork fills the whole page as a background
/// (with a dark scrim so text stays legible), matching watchOS's own Music app Now Playing screen,
/// rather than a small foreground artwork tile. The progress bar is display-only — seeking via the
/// Digital Crown was deliberately dropped (prev/next remain the only way to change tracks) — and the
/// Crown instead drives the system volume row below the shuffle/repeat controls, matching how
/// Apple's own Music app dedicates the Crown to volume on its Now Playing screen.
struct WatchNowPlayingView: View {
    @EnvironmentObject private var player: WatchAudioPlayerService
    @EnvironmentObject private var library: WatchLocalLibrary
    /// Injected separately from `player` so this page (and only this page) observes the 0.5s
    /// position tick — see `WatchPlaybackProgress`'s doc comment for why that split fixes the
    /// stutter that used to happen when swiping between Library and Now Playing.
    @EnvironmentObject private var progress: WatchPlaybackProgress

    private var duration: Double { max(player.currentSong?.duration ?? 0, 1) }

    /// Decoded artwork for `player.currentSong`, cached so it is only re-read from disk and
    /// re-decoded when the track actually changes — not on every body evaluation. This view also
    /// observes `progress` (the 0.5s position tick), so a plain computed property here would decode
    /// the JPEG from disk and re-decode it every half second purely to redraw the full-bleed
    /// background, which is wasted main-thread I/O/CPU on every single tick and a plausible
    /// contributor to the playback stutter reported when this page is visible.
    @State private var cachedArtworkImage: UIImage?
    @State private var cachedArtworkSongId: String?

    var body: some View {
        ZStack {
            backgroundArtwork
            content
        }
        .onAppear { refreshCachedArtworkIfNeeded() }
        .onChange(of: player.currentSong?.id) { _, _ in refreshCachedArtworkIfNeeded() }
    }

    /// Full-bleed background: the cached artwork scaled to fill the page, with a dark scrim so the
    /// title/artist/controls stay legible over any artwork. Falls back to `RemoteDefaultArtwork` —
    /// a bundled copy of the desktop app's default artwork jacket — when there is no artwork yet,
    /// so the idle state gets the same blur/opacity/scrim treatment as the playing state instead of
    /// a plain black page.
    @ViewBuilder
    private var backgroundArtwork: some View {
        if let cachedArtworkImage {
            fullBleedArtwork(Image(uiImage: cachedArtworkImage))
        } else {
            fullBleedArtwork(Image("RemoteDefaultArtwork"))
        }
    }

    /// Shared full-bleed treatment (scaled to fill, dark scrim overlay) applied to both the real
    /// cached artwork and the `RemoteDefaultArtwork` idle fallback so the two states look alike.
    ///
    /// `scaledToFill()` deliberately overflows whatever frame precedes it (that is how "fill" mode
    /// avoids empty gaps), so without an explicit frame + `.clipped()` afterwards, the oversized
    /// image paints outside this view's own bounds. That overflow used to bleed into the
    /// neighbouring Queue page while swiping between pages in the paged `TabView` (`WatchRootView`)
    /// — the TabView can render adjacent pages' content during a swipe transition, and unclipped
    /// content isn't confined to its own page. `GeometryReader` here supplies the exact page size
    /// (via `.ignoresSafeArea()` on the reader itself, so `proxy.size` already spans the full
    /// screen including safe areas); the image is then explicitly framed to that same size and
    /// `.clipped()`, so it still covers the whole page but can never draw a pixel beyond it.
    @ViewBuilder
    private func fullBleedArtwork(_ image: Image) -> some View {
        GeometryReader { proxy in
            image
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .overlay {
                    LinearGradient(
                        colors: [Color.black.opacity(0.75), Color.black.opacity(0.35), Color.black.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .ignoresSafeArea()
    }

    /// Reloads `cachedArtworkImage` from disk only when the current song has actually changed —
    /// see the doc comment on `cachedArtworkImage` for why this must not run on every redraw.
    private func refreshCachedArtworkIfNeeded() {
        guard let song = player.currentSong else {
            cachedArtworkImage = nil
            cachedArtworkSongId = nil
            return
        }
        guard cachedArtworkSongId != song.id else { return }
        cachedArtworkSongId = song.id
        guard
            let url = library.artworkFileURLIfPresent(for: song),
            let data = try? Data(contentsOf: url)
        else {
            cachedArtworkImage = nil
            return
        }
        cachedArtworkImage = UIImage(data: data)
    }

    @ViewBuilder
    private var content: some View {
        // A `ScrollView` (rather than a bare `VStack`) so the page degrades gracefully on the
        // smallest watch screens (e.g. Series 11 42mm) instead of clipping/overflowing past the
        // bottom edge — the fixed paddings/spacings below were sized for larger screens and left
        // the shuffle/repeat row pushed off-screen on 42mm. `.scrollBounceBehavior(.basedOnSize)`
        // below keeps this from scrolling/bouncing on screens where the content already fits,
        // while still allowing 42mm to scroll.
        ScrollView {
            VStack(spacing: 8) {
                VStack(spacing: 2) {
                    Text(player.currentSong?.displayTitle ?? "再生していません")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(player.currentSong?.displayArtist ?? "—")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }

                if let routeError = player.routeError {
                    Text(routeError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if player.currentSong != nil {
                    // Display-only: no Crown/tap seeking — see the type-level doc comment for why.
                    VStack(spacing: 2) {
                        ProgressView(value: progress.position, total: duration)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                        HStack {
                            Text(formatTime(progress.position))
                            Spacer()
                            Text("-\(formatTime(max(duration - progress.position, 0)))")
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.7))
                    }
                }

                HStack(spacing: 16) {
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 20) {
                    Button { player.toggleShuffle() } label: {
                        shuffleIcon
                    }
                    .buttonStyle(.plain)

                    Button { player.cycleRepeatMode() } label: {
                        repeatIcon
                    }
                    .buttonStyle(.plain)
                }

                // Slim system volume row: the Digital Crown's sole job on this page (see the
                // type-level doc comment) is adjusting volume, not seeking. `autoFocusesCrown`
                // requests Crown focus for this specific control as soon as it appears, so rotating
                // the Crown here changes the volume immediately without needing a tap first.
                HStack(spacing: 4) {
                    Image(systemName: "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                    SystemVolumeControl(autoFocusesCrown: true)
                        .frame(height: 26)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("再生中")
    }

    /// Desktop app's shuffle icon (`random.svg`), reused as a watchOS template image so it tints via
    /// `.foregroundStyle` like the SF Symbol it replaces. Sized well above the old `.caption` glyph
    /// (20pt) inside a 36pt tap frame, per Apple's minimum touch-target guidance for watchOS.
    @ViewBuilder
    private var shuffleIcon: some View {
        Image("DesktopShuffleIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .foregroundStyle(player.isShuffled ? .blue : .white.opacity(0.6))
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }

    /// Desktop app's repeat icon (`repeat.svg`), reused the same way as `shuffleIcon`. The desktop
    /// SVG only has one repeat glyph (no "repeat one" variant), so the `.one` state is rendered as
    /// the same icon with a small filled "1" badge overlaid in the corner, tinted like the active
    /// state — cheaper than shipping a second asset and keeps the active/inactive tint logic
    /// unchanged from before.
    @ViewBuilder
    private var repeatIcon: some View {
        let tint: Color = player.repeatMode == .off ? .white.opacity(0.6) : .blue
        ZStack(alignment: .bottomTrailing) {
            Image("DesktopRepeatIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(tint)

            if player.repeatMode == .one {
                Text("1")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 11, height: 11)
                    .background(Circle().fill(tint))
            }
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    let library = WatchLocalLibrary()
    let player = WatchAudioPlayerService(library: library)
    WatchNowPlayingView()
        .environmentObject(player)
        .environmentObject(player.progress)
        .environmentObject(library)
}
