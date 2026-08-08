import SwiftUI
import UIKit

/// Now Playing page: always reachable via the paged `TabView` in `WatchRootView`, regardless of
/// what is selected on the Library page. The cached artwork fills the whole page as a background
/// (with a dark scrim so text stays legible), matching watchOS's own Music app Now Playing screen,
/// rather than a small foreground artwork tile. The progress bar is display-only — seeking via the
/// Digital Crown was deliberately dropped (prev/next remain the only way to change tracks) — and the
/// Crown instead drives the system volume, matching how Apple's own Music app dedicates the Crown
/// to volume on its Now Playing screen. There is no visible volume row (an earlier version had one,
/// but it pushed the page past 45mm-screen height); instead a `SystemVolumeControl` sized down to
/// near-nothing keeps Crown focus, and `WatchVolumeHUDOverlay` shows a transient macOS-style
/// vertical gauge whenever the level actually changes — see `WatchVolumeHUD.swift`.
struct WatchNowPlayingView: View {
    @EnvironmentObject private var player: WatchAudioPlayerService
    @EnvironmentObject private var library: WatchLocalLibrary
    /// Injected separately from `player` so this page (and only this page) observes the 0.5s
    /// position tick — see `WatchPlaybackProgress`'s doc comment for why that split fixes the
    /// stutter that used to happen when swiping between Library and Now Playing.
    @EnvironmentObject private var progress: WatchPlaybackProgress

    @StateObject private var volumeObserver = WatchVolumeObserver()

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
            hiddenCrownVolumeControl
            WatchVolumeHUDOverlay(level: volumeObserver.level)
        }
        .onAppear { refreshCachedArtworkIfNeeded() }
        .onChange(of: player.currentSong?.id) { _, _ in refreshCachedArtworkIfNeeded() }
    }

    /// `SystemVolumeControl` shrunk to near-invisibility rather than removed outright: its whole
    /// purpose here is to keep taking Digital Crown focus (`autoFocusesCrown: true`) so rotating
    /// the Crown adjusts system volume without a visible control cluttering the page — the visible
    /// feedback comes entirely from `WatchVolumeHUDOverlay` above, driven by the KVO-observed
    /// `outputVolume` change that the Crown rotation causes. Sized to 1×1 with near-zero (not
    /// literally zero) opacity, since a fully invisible/zero-opacity control risks not being
    /// eligible to take Crown focus on some watchOS versions.
    private var hiddenCrownVolumeControl: some View {
        SystemVolumeControl(autoFocusesCrown: true)
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .accessibilityHidden(true)
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
        // bottom edge. The paddings/spacings below are tuned so the *playing* state — title/artist,
        // route error (if any), progress bar + elapsed/remaining times, transport row, and
        // shuffle/repeat row — fits without scrolling on 45mm-class screens and larger (the
        // progress block is what pushes the idle-state height over the edge, since it only renders
        // while a song is current). `.scrollBounceBehavior(.basedOnSize)` keeps this from
        // scrolling/bouncing on screens where the content already fits, while still allowing the
        // smallest watches (40/41mm) to scroll instead of clipping.
        ScrollView {
            VStack(spacing: 5) {
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
                            .font(.system(size: 34))
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
                        WatchShuffleIcon(isActive: player.isShuffled)
                    }
                    .buttonStyle(.plain)

                    Button { player.cycleRepeatMode() } label: {
                        WatchRepeatIcon(repeatMode: player.repeatMode)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("再生中")
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
