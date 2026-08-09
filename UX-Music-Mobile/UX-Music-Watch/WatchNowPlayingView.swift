import SwiftUI
import UIKit

/// Now Playing page: always reachable via the paged `TabView` in `WatchRootView`, regardless of
/// what is selected on the Library page. The cached artwork fills the whole page as a background
/// (with a dark scrim so text stays legible), matching watchOS's own Music app Now Playing screen,
/// rather than a small foreground artwork tile. The progress bar is display-only — seeking via the
/// Digital Crown was deliberately dropped (prev/next remain the only way to change tracks) — and the
/// Crown instead drives the system volume, matching how Apple's own Music app dedicates the Crown
/// to volume on its Now Playing screen. There is no visible volume row (an earlier version had one,
/// but it pushed the page past 45mm-screen height); instead a `SystemVolumeControl` keeps Crown
/// focus (see `hiddenCrownVolumeControl`'s doc comment), and `WatchVolumeHUDOverlay` shows a
/// transient macOS-style vertical gauge whenever the level actually changes — see
/// `WatchVolumeHUD.swift`.
///
/// ## Layout: `ViewThatFits`, not hand-tuned metrics
///
/// Two earlier rounds of this view hardcoded a single set of spacings/paddings/glyph sizes, each
/// tuned against a screenshot of the worst case seen at the time — and each round still overflowed
/// (`ScrollView` kicking in, which per `hiddenCrownVolumeControl` also lets the Digital Crown steal
/// focus from volume) as soon as content or the device changed. That approach cannot work in
/// principle: Apple Watch ships at least six screen heights (40/41/42/44/45/46/49mm), watchOS lets
/// the user scale text via Dynamic Type (changing `.headline`/`.caption2`/etc. line heights
/// independently of screen size), and the content itself varies (the route-error line only appears
/// sometimes). Any single fixed constant is correct for one point in that combined space and wrong
/// for others — there is no constant that is simultaneously "tight enough for 40mm at the largest
/// Dynamic Type size with a route error" and "not comically cramped on a 49mm Ultra with default
/// text". Hand-tuning is chasing a moving target.
///
/// `content` below instead offers `ViewThatFits(in: .vertical)` a ladder of candidates, each built
/// from the same `nowPlayingStack(_:)` with different `NowPlayingMetrics`, from roomiest to most
/// compact:
/// 1. **`.roomy`** — every element (title/artist, route error when present, progress bar with
///    elapsed/remaining times, transport row, shuffle/repeat row), generous spacing and glyph sizes.
/// 2. **`.compact`** — the same elements, tighter spacing/smaller glyphs.
/// 3. **`.reduced`** — drops the elapsed/remaining time row (the progress bar itself stays), tighter
///    still.
/// 4. **A `ScrollView` wrapping `.reduced`** — the last-resort fallback, so devices/content/text-size
///    combinations too tight for any of the first three (measured on-device: the smallest watch
///    combined with the route-error line, even at default Dynamic Type; larger watches with the
///    route-error line still land on `.reduced` without scrolling) degrade to scrolling instead of
///    clipping.
///
/// `ViewThatFits` measures each candidate's actual rendered height — on the real device, at the
/// user's real text size, with the real content (route error present or not) — and picks the first
/// one that genuinely fits the space SwiftUI actually proposes for this page. No per-device magic
/// numbers, and nothing to re-tune the next time a screen size or content line is added.
///
/// Candidates 1–3 deliberately contain **no `ScrollView`**, so on any device where content fits at
/// all, nothing on this page is scrollable — which matters beyond just avoiding clipping: watchOS
/// scrolls scrollable content with the Digital Crown by default, and this page instead wants the
/// Crown dedicated to volume (see `hiddenCrownVolumeControl`). A stray `ScrollView` on a page whose
/// hidden volume control fails to hold Crown focus would silently fall back to scrolling the page
/// instead of changing the volume; keeping candidates 1–3 scroll-free removes that failure mode
/// entirely for the vast majority of device/text-size/content combinations, regardless of how
/// reliably Crown focus is held. Only candidate 4 — reached solely under the most extreme
/// combination — brings a `ScrollView` back, and at that point scrolling instead of clipping is the
/// correct outcome anyway.
struct WatchNowPlayingView: View {
    @EnvironmentObject private var player: WatchAudioPlayerService
    @EnvironmentObject private var library: WatchLocalLibrary
    /// Injected separately from `player` so this page (and only this page) observes the 0.5s
    /// position tick — see `WatchPlaybackProgress`'s doc comment for why that split fixes the
    /// stutter that used to happen when swiping between Library and Now Playing.
    @EnvironmentObject private var progress: WatchPlaybackProgress

    /// Whether this page is the one currently selected in `WatchRootView`'s paged `TabView`, passed
    /// down from `selectedPage` there. **Required** for `hiddenCrownVolumeControl` — see its doc
    /// comment for why `onAppear` alone cannot be trusted to mean "became visible" on this page.
    let isActive: Bool

    @StateObject private var volumeObserver = WatchVolumeObserver()

    /// Bumped whenever `isActive` becomes `true` (see `onChange` below) so `hiddenCrownVolumeControl`
    /// re-requests Crown focus each time this page is actually paged to, not just once for the
    /// lifetime of the view — see that property's doc comment.
    @State private var crownRefocusTrigger = 0

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
        .onAppear {
            refreshCachedArtworkIfNeeded()
        }
        .onChange(of: player.currentSong?.id) { _, _ in refreshCachedArtworkIfNeeded() }
        .onChange(of: isActive) { _, active in
            // Only the transition *to* active matters — see `hiddenCrownVolumeControl`'s doc
            // comment for why re-focusing must be gated on this rather than `onAppear`.
            if active { crownRefocusTrigger += 1 }
        }
    }

    /// `SystemVolumeControl` kept invisible rather than removed outright: its whole purpose here is
    /// to keep taking Digital Crown focus (`autoFocusesCrown:`) so rotating the Crown adjusts system
    /// volume without a visible control cluttering the page — the visible feedback comes entirely
    /// from `WatchVolumeHUDOverlay` above, driven by the KVO-observed `outputVolume` change that the
    /// Crown rotation causes.
    ///
    /// **`autoFocusesCrown` is tied to `isActive`, not hardcoded `true` — this is load-bearing, not
    /// cosmetic.** `WatchRootView`'s paged `TabView` keeps adjacent pages mounted (so paging back to
    /// them is instant), which means this view's `onAppear`/`body` keep re-running even while the
    /// Queue & Volume page is the one actually on screen. Earlier versions called
    /// `wkInterfaceObject.focus()` unconditionally whenever `onAppear` fired, on the assumption that
    /// "appeared" meant "became visible" — it does not, for a kept-alive adjacent page. Calling
    /// `focus()` on a `WKInterfaceVolumeControl` that is not part of the *currently front* interface
    /// controller does not just fail to grab the Crown: it walks WatchKit's responder chain
    /// (`becomeFirstResponder` → `_UIHostingView._didChange(toFirstResponder:)`) back into SwiftUI's
    /// AttributeGraph while that graph is already mid-update, which the graph detects as a dependency
    /// cycle. Confirmed by sampling the pegged process (`sample <pid>`, watchOS 26 Simulator): 100% of
    /// main-thread samples sat inside this exact call chain, spending most of their time in
    /// `AG::Graph::UpdateStack::push_slow`/`update()` (occasionally `print_cycle`, which itself burns
    /// CPU in `fprintf`) — the main run loop never got back control, so neither the page swipe nor the
    /// Digital Crown did anything. Gating `autoFocusesCrown` on `isActive` stops `focus()` from ever
    /// being called while this page is off-screen, which removes the trigger at its source. (A
    /// regression introduced in 7b8f532 — see `progress/watch-ui-redesign.md` for the full bisect.)
    ///
    /// Two further robustness measures beyond the original 1×1/0.02-opacity control:
    /// - **Larger frame (44×44, watchOS's usual minimum tap-target size)** rather than 1×1. A 1pt
    ///   target is imperceptible visually either way at this opacity, but WatchKit's own Crown-focus
    ///   machinery is more likely to treat a near-zero-size element as not worth focusing than a
    ///   normally-sized one. `.allowsHitTesting(false)` keeps the larger frame from ever intercepting
    ///   taps meant for the transport buttons it overlaps in the `ZStack`.
    /// - **Re-focus on every genuine page appearance, not only once.** `SystemVolumeControl`'s
    ///   `refocusTrigger` is compared against the last value it focused at; `crownRefocusTrigger`
    ///   above increments only when `isActive` turns `true` (see the `onChange` above), so returning
    ///   to this page after paging to Library or Queue re-requests focus instead of assuming a focus
    ///   grabbed once, long ago, is still held.
    private var hiddenCrownVolumeControl: some View {
        SystemVolumeControl(autoFocusesCrown: isActive, refocusTrigger: crownRefocusTrigger)
            .frame(width: 44, height: 44)
            .opacity(0.02)
            .allowsHitTesting(false)
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

    /// See the type-level doc comment for the `ViewThatFits` ladder this builds. Each candidate is
    /// the same `nowPlayingStack(_:)` content, just parameterised by `NowPlayingMetrics`; the final
    /// candidate additionally wraps it in a `ScrollView` as a last-resort fallback.
    @ViewBuilder
    private var content: some View {
        ViewThatFits(in: .vertical) {
            nowPlayingStack(.roomy)
            nowPlayingStack(.compact)
            nowPlayingStack(.reduced)
            ScrollView {
                nowPlayingStack(.reduced)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("再生中")
    }

    /// Builds one `ViewThatFits` candidate at the given compactness level. Structural content is
    /// identical across all callers (title/artist, optional route error, progress block shown only
    /// while a song is current, transport row, shuffle/repeat row) — only spacing, padding, and
    /// glyph sizes vary, via `metrics`.
    @ViewBuilder
    private func nowPlayingStack(_ metrics: NowPlayingMetrics) -> some View {
        VStack(spacing: metrics.stackSpacing) {
            VStack(spacing: metrics.titleArtistSpacing) {
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
                    .font(metrics.routeErrorFont)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if player.currentSong != nil {
                // Display-only: no Crown/tap seeking — see the type-level doc comment for why.
                VStack(spacing: metrics.progressBlockSpacing) {
                    ProgressView(value: progress.position, total: duration)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                    if metrics.showsTimeRow {
                        HStack {
                            Text(formatTime(progress.position))
                            Spacer()
                            Text("-\(formatTime(max(duration - progress.position, 0)))")
                        }
                        .font(metrics.timeFont)
                        .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            HStack(spacing: metrics.transportSpacing) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill")
                        .font(metrics.transportGlyphFont)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: metrics.playButtonPointSize))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(metrics.transportGlyphFont)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: metrics.modeRowSpacing) {
                Button { player.toggleShuffle() } label: {
                    WatchShuffleIcon(isActive: player.isShuffled, iconSize: metrics.modeIconSize, tapFrameSize: metrics.modeTapFrameSize)
                }
                .buttonStyle(.plain)

                Button { player.cycleRepeatMode() } label: {
                    WatchRepeatIcon(repeatMode: player.repeatMode, iconSize: metrics.modeIconSize, tapFrameSize: metrics.modeTapFrameSize)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.verticalPadding)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One point on the `ViewThatFits` compactness ladder documented on `WatchNowPlayingView` —
/// spacing, padding, and glyph sizes for a single candidate. Pure data; `nowPlayingStack(_:)`
/// applies it, `ViewThatFits` decides which one is actually used, per device/text-size/content.
private struct NowPlayingMetrics {
    var stackSpacing: CGFloat
    var titleArtistSpacing: CGFloat
    var progressBlockSpacing: CGFloat
    /// Whether the elapsed/remaining time row is shown below the progress bar. `false` only for
    /// `.reduced` — the one element the ladder sheds before resorting to a `ScrollView`.
    var showsTimeRow: Bool
    var timeFont: Font
    /// Font for the route-error line (when `player.routeError` is set). Kept smaller on the
    /// tighter tiers so the (often three-line) error message wraps to fewer lines instead of
    /// dominating the available height — measured to matter more than any other single lever here.
    var routeErrorFont: Font
    var transportSpacing: CGFloat
    var transportGlyphFont: Font
    var playButtonPointSize: CGFloat
    var modeRowSpacing: CGFloat
    var modeIconSize: CGFloat
    var modeTapFrameSize: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat

    /// Everything, comfortably spaced — the candidate `ViewThatFits` prefers whenever there is room
    /// to spare (larger watches, default Dynamic Type).
    static let roomy = NowPlayingMetrics(
        stackSpacing: 10, titleArtistSpacing: 4, progressBlockSpacing: 4, showsTimeRow: true,
        timeFont: .system(size: 11), routeErrorFont: .caption2, transportSpacing: 22,
        transportGlyphFont: .title2, playButtonPointSize: 40, modeRowSpacing: 26, modeIconSize: 22,
        modeTapFrameSize: 36, horizontalPadding: 16, verticalPadding: 8
    )

    /// Everything, tightened — roughly the metrics the previous hand-tuned single-layout version
    /// used (spacing 5 / padding 12,4 / 34pt play button), now just one rung of the ladder instead
    /// of the only option.
    static let compact = NowPlayingMetrics(
        stackSpacing: 5, titleArtistSpacing: 2, progressBlockSpacing: 2, showsTimeRow: true,
        timeFont: .system(size: 9), routeErrorFont: .system(size: 10), transportSpacing: 16,
        transportGlyphFont: .title3, playButtonPointSize: 34, modeRowSpacing: 20, modeIconSize: 20,
        modeTapFrameSize: 36, horizontalPadding: 12, verticalPadding: 4
    )

    /// Drops the elapsed/remaining time row (the progress bar itself is kept) and tightens further
    /// still — the last non-scrolling rung before the `ScrollView` fallback.
    static let reduced = NowPlayingMetrics(
        stackSpacing: 3, titleArtistSpacing: 1, progressBlockSpacing: 0, showsTimeRow: false,
        timeFont: .system(size: 9), routeErrorFont: .system(size: 9), transportSpacing: 10,
        transportGlyphFont: .system(size: 16), playButtonPointSize: 28, modeRowSpacing: 12,
        modeIconSize: 16, modeTapFrameSize: 28, horizontalPadding: 8, verticalPadding: 0
    )
}

#Preview {
    let library = WatchLocalLibrary()
    let player = WatchAudioPlayerService(library: library)
    WatchNowPlayingView(isActive: true)
        .environmentObject(player)
        .environmentObject(player.progress)
        .environmentObject(library)
}
