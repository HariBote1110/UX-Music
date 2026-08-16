import SwiftUI
import UIKit

/// `internal` (not `private`) so the lyrics screen can share the same fallback tint.
let nowPlayingFallbackAccent = Color(red: 0.45, green: 0.82, blue: 1.0)

/// `internal` (not `private`) so unit tests can drive `nowPlayingSidePanelCoverage` directly.
enum NowPlayingPage: Equatable {
    case main
    case queue
    case favourites
    case playbackSettings
}

private enum StripDragAxis {
    case horizontal
    case vertical
}

private let nowPlayingPanelSpring = Animation.spring(response: 0.52, dampingFraction: 0.78, blendDuration: 0.12)

func stripBaseX(page: NowPlayingPage, width w: CGFloat) -> CGFloat {
    switch page {
    case .main: return -w
    case .queue: return 0
    case .favourites: return -2 * w
    case .playbackSettings: return -w
    }
}

/// Rubber-band slightly past [-2w, 0] for a softer feel while dragging.
func displayStripOffset(page: NowPlayingPage, horizontalDrag: CGFloat, width w: CGFloat) -> CGFloat {
    guard w > 1 else { return 0 }
    guard page != .playbackSettings else { return -w }
    let base = stripBaseX(page: page, width: w)
    var raw = base + horizontalDrag
    let minX = -2 * w
    let maxX: CGFloat = 0
    if raw < minX {
        let over = raw - minX
        raw = minX + over * 0.35
    } else if raw > maxX {
        let over = raw - maxX
        raw = maxX + over * 0.45
    }
    return raw
}

/// How much a black safe-area cover should show (0…1) above the ambient background while the
/// swipeable side-panel strip is dragged or settled on a side panel.
///
/// The ambient background is rendered full-screen (outside every `.clipped()` panel) so it can
/// reach the status-bar and home-indicator bands, but the Queue / Favourites / PlaybackSettings
/// panels only cover the safe-area-respecting content region. Without this cover, those bands
/// keep showing ambient gradient behind a panel that is supposed to be solid black.
///
/// `page == .playbackSettings` is a full-screen overlay, so coverage is always 1. Otherwise
/// coverage tracks how far the strip has moved away from the "main" resting position (`-w`),
/// clamped to `[0, 1]` so rubber-band overshoot never exceeds full coverage.
func nowPlayingSidePanelCoverage(page: NowPlayingPage, horizontalDrag: CGFloat, width w: CGFloat) -> CGFloat {
    guard w > 1 else { return 0 }
    if page == .playbackSettings { return 1 }
    let offset = displayStripOffset(page: page, horizontalDrag: horizontalDrag, width: w)
    let coverage = abs(offset + w) / w
    return min(1, max(0, coverage))
}

/// How far the drag-to-reveal PlaybackSettings sheet has been lifted from the bottom edge,
/// as a fraction of the content height (0 = resting off-screen below, 1 = fully raised).
///
/// Only upward drags (`dragTranslationY < 0`) lift the sheet; downward drags are clamped to 0
/// so the same live translation value used for the main page's vertical-axis gesture can be
/// fed straight in without a separate "is this an upward drag" branch at every call site.
func nowPlayingSettingsSheetProgress(dragTranslationY ty: CGFloat, height h: CGFloat) -> CGFloat {
    guard h > 1 else { return 0 }
    let liftedUp = max(0, -ty)
    return min(1, liftedUp / h)
}

/// Vertical offset (in points, measured from the sheet's fully-raised resting position) for the
/// given lift `progress`. `0` progress parks the sheet a full height below (off-screen), `1`
/// progress sits it flush at the top of the content area.
func nowPlayingSettingsSheetOffsetY(progress: CGFloat, height h: CGFloat) -> CGFloat {
    let clamped = min(1, max(0, progress))
    return h * (1 - clamped)
}

/// How much to dim the content behind the rising sheet (0...0.5), scaling linearly with lift
/// `progress` so the backdrop darkens smoothly as the sheet is dragged up, capping below full
/// black so the sheet itself always reads as the brighter, foreground layer.
func nowPlayingSettingsSheetDarkness(progress: CGFloat) -> CGFloat {
    let clamped = min(1, max(0, progress))
    return clamped * 0.5
}

/// Release-time decision: does the drag gesture end with enough lift `progress` to commit to
/// opening the PlaybackSettings sheet, or should it spring back down?
func nowPlayingSettingsSheetShouldOpen(progress: CGFloat) -> Bool {
    progress > 0.22
}

/// Translates `List.onMove`'s `destination` — a "gap index in the original array" (the same
/// convention as the classic `RangeReplaceableCollection.move(fromOffsets:toOffset:)` helper) —
/// into the final resting index `MusicPlayerService.moveQueueItem(from:to:)` expects (the
/// item's index in the *resulting* array). Moving forward past the vacated slot shifts every
/// later index down by one; moving backward needs no adjustment.
func nowPlayingQueueMoveDestination(from: Int, to: Int) -> Int {
    from < to ? to - 1 : to
}

/// `ToolbarItem` can propose a short height; large frames get clipped and `Circle()` looks truncated.
/// `internal` (not `private`) so the lyrics screen's close button can reuse the same chrome.
struct NowPlayingNavIconButton<Content: View>: View {
    let action: () -> Void
    let accessibilityLabel: String
    @ViewBuilder var label: () -> Content

    private let diameter: CGFloat = 34

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                label()
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page: NowPlayingPage = .main
    @State private var horizontalDrag: CGFloat = 0
    @State private var lockedDragAxis: StripDragAxis?
    /// Live vertical drag translation (points) while dragging the PlaybackSettings sheet up from
    /// the main page. Negative values lift the sheet; kept at 0 whenever not mid-drag.
    @State private var settingsDragOffset: CGFloat = 0
    @State private var showLyricsScreen = false
    /// Palette extracted from the current track's artwork.
    /// Kept at this level so the ambient background can be applied *outside* the
    /// NavigationStack (bypassing the .clipped() strip panel) and therefore
    /// extend into the safe-area regions at the top and bottom of the screen.
    @State private var ambientPalette: ArtworkPlaybackPalette?

    var body: some View {
        // Structure:
        //   ZStack
        //   ├─ NowPlayingAmbientBackground  (.ignoresSafeArea(.all))
        //   │    Covers the FULL device screen including the status-bar and home-indicator
        //   │    regions.  This is the definitive fix for the solid-black safe-area bands:
        //   │    the ambient gradient lives *outside* every .clipped() panel, so nothing
        //   │    blocks it from reaching the screen edges.
        //   └─ GeometryReader  (normal — respects safe areas)
        //        geo.size = content area (status-bar and home-indicator already excluded).
        //        Toolbar buttons are placed at padding(.top, 8) from the content-area origin,
        //        which is already below the status-bar / Dynamic Island.
        //        Panel content receives `toolbarClearance` so VStack spacers clear the buttons.
        //        Its innermost ZStack's back-most layer is a `.ignoresSafeArea()` black cover
        //        whose opacity tracks `nowPlayingSidePanelCoverage`, so the safe-area bands go
        //        solid black in step with the Queue / Favourites / PlaybackSettings panels
        //        instead of leaking the ambient gradient behind them.
        ZStack {
            // ── Full-screen ambient background ─────────────────────────────────────
            NowPlayingAmbientBackground(palette: ambientPalette)
                .ignoresSafeArea(.all)
                .animation(.easeInOut(duration: 0.5), value: ambientPalette)

            // ── Content (safe-area-aware) ──────────────────────────────────────────
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                // Extra vertical clearance needed inside the content area so that panel
                // content is not obscured by the floating toolbar row (button ø34 + margins).
                let toolbarClearance: CGFloat = 52
                // While settled on the settings page the sheet is fully raised (progress 1);
                // otherwise progress tracks the live upward drag from the main page.
                let settingsSheetProgress: CGFloat = page == .playbackSettings
                    ? 1
                    : nowPlayingSettingsSheetProgress(dragTranslationY: settingsDragOffset, height: h)

                ZStack(alignment: .top) {
                    // ── Safe-area cover ──────────────────────────────────────────────
                    // Sits behind the strip but in front of the full-screen ambient
                    // background, so the status-bar / home-indicator bands go solid
                    // black in step with the side panels instead of leaking gradient.
                    Color.black
                        .opacity(nowPlayingSidePanelCoverage(page: page, horizontalDrag: horizontalDrag, width: w))
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    // ── Sheet backdrop dimming ───────────────────────────────────────
                    // Darkens the main page as the PlaybackSettings sheet is dragged up from
                    // the bottom edge, independent of the side-panel safe-area cover above.
                    Color.black
                        .opacity(nowPlayingSettingsSheetDarkness(progress: settingsSheetProgress))
                        .ignoresSafeArea()
                        .allowsHitTesting(false)

                    // ── Horizontal panel strip ──────────────────────────────────────
                    HStack(spacing: 0) {
                        NowPlayingQueuePanel(page: $page, topInset: toolbarClearance)
                            .frame(width: w, height: h)
                            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 32, style: .continuous)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                            }
                        Group {
                            if let song = model.player.currentSong {
                                NowPlayingPlayingShell(
                                    song: song,
                                    artworkId: song.artworkId,
                                    artworkURLString: model.artworkURL(for: song.artworkId),
                                    palette: $ambientPalette,
                                    topInset: toolbarClearance,
                                    bottomInset: 0
                                )
                            } else {
                                NowPlayingEmptyChrome()
                            }
                        }
                        .frame(width: w, height: h)
                        NowPlayingFavouritesPanel(page: $page, topInset: toolbarClearance)
                            .frame(width: w, height: h)
                            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 32, style: .continuous)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                            }
                    }
                    .frame(width: 3 * w, height: h, alignment: .leading)
                    .offset(
                        x: displayStripOffset(page: page, horizontalDrag: horizontalDrag, width: w)
                            + (page == .playbackSettings ? -3 * w : 0)
                    )
                    .frame(width: w, height: h, alignment: .leading)
                    .clipped()
                    .allowsHitTesting(page != .playbackSettings)
                    .gesture(stripDragGesture(width: w, height: h))

                    // ── Playback-settings sheet ─────────────────────────────────────
                    // Rendered unconditionally (not just when `page == .playbackSettings`) so
                    // `offset(y:)` — not a `.transition` — can track the finger continuously
                    // during the drag-up gesture from the main page and animate smoothly back
                    // to fully hidden/shown on release, instead of popping in from a fixed edge.
                    NowPlayingPlaybackSettingsPanel(page: $page, topInset: toolbarClearance)
                        .frame(width: w, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                        }
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(.white.opacity(0.3))
                                .frame(width: 36, height: 5)
                                .padding(.top, 8)
                        }
                        .offset(y: nowPlayingSettingsSheetOffsetY(progress: settingsSheetProgress, height: h))
                        .allowsHitTesting(page == .playbackSettings)
                        .zIndex(1)

                    // ── Floating toolbar ────────────────────────────────────────────
                    // y=0 inside this GeometryReader is already below the status bar /
                    // Dynamic Island because the GeometryReader respects safe areas.
                    HStack(alignment: .center) {
                        leadingNavButton
                        Spacer()
                        trailingNavButtons
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .allowsHitTesting(page != .playbackSettings)
                    .zIndex(2)
                }
                .frame(width: w, height: h)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(page == .favourites || page == .queue || page == .playbackSettings)
        .fullScreenCover(isPresented: $showLyricsScreen) {
            if let song = model.player.currentSong {
                NowPlayingLyricsScreen(song: song, palette: ambientPalette, isPresented: $showLyricsScreen)
                    .environment(model)
            }
        }
        .onAppear {
            horizontalDrag = 0
            lockedDragAxis = nil
            if model.debugForceOpenLyrics {
                showLyricsScreen = true
            }
        }
        .onChange(of: model.player.currentSong) { _, newSong in
            if newSong == nil { ambientPalette = nil }
        }
    }

    // MARK: Floating toolbar buttons

    @ViewBuilder private var leadingNavButton: some View {
        if page == .main {
            NowPlayingNavIconButton(action: { dismiss() }, accessibilityLabel: "Close") {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        } else {
            NowPlayingNavIconButton(action: {
                withAnimation(nowPlayingPanelSpring) {
                    page = .main
                    horizontalDrag = 0
                }
            }, accessibilityLabel: "Back to player") {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    @ViewBuilder private var trailingNavButtons: some View {
        if page == .main, let song = model.player.currentSong {
            HStack(spacing: 10) {
                NowPlayingNavIconButton(action: {
                    showLyricsScreen = true
                }, accessibilityLabel: "Show lyrics") {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            !song.isYouTube && model.hasLocalLyricsFile(for: song.id)
                                ? Color.white.opacity(0.9)
                                : Color.white.opacity(0.38)
                        )
                }
                .disabled(song.isYouTube)
                NowPlayingNavIconButton(action: {
                    model.toggleFavourite(songId: song.id)
                }, accessibilityLabel: "Favourite") {
                    Image(systemName: model.isFavouriteSong(songId: song.id) ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(model.isFavouriteSong(songId: song.id) ? Color.pink : Color.white.opacity(0.85))
                }
            }
        }
    }

    private func setHorizontalDragLive(_ value: CGFloat) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            horizontalDrag = value
        }
    }

    private func setSettingsDragLive(_ value: CGFloat) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            settingsDragOffset = value
        }
    }

    private func stripDragGesture(width w: CGFloat, height h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard page != .playbackSettings, w > 1, h > 1 else { return }
                let tx = value.translation.width
                let ty = value.translation.height
                let startY = value.startLocation.y

                if lockedDragAxis == nil {
                    let dist = hypot(tx, ty)
                    guard dist > 10 else { return }
                    switch page {
                    case .main:
                        // Artwork + title/metadata sit below the top half; only reserve the bottom band
                        // (transport + scrubber) for vertical-only drags so pull-down dismiss still wins there.
                        let horizontalStripFriendlyTopFraction: CGFloat = 0.82
                        if abs(tx) >= abs(ty) {
                            lockedDragAxis = startY < h * horizontalStripFriendlyTopFraction ? .horizontal : .vertical
                        } else {
                            lockedDragAxis = .vertical
                        }
                    case .favourites, .queue:
                        // Horizontal strip only: vertical motion is for list scrolling / no sheet actions.
                        guard abs(tx) >= abs(ty) else { return }
                        lockedDragAxis = .horizontal
                    case .playbackSettings:
                        break
                    }
                }

                if lockedDragAxis == .vertical, page == .main {
                    // Only upward motion lifts the PlaybackSettings sheet; downward motion is
                    // left alone here so the existing pull-down-to-dismiss threshold below still
                    // sees the raw translation.
                    setSettingsDragLive(min(0, ty))
                    return
                }

                guard lockedDragAxis == .horizontal else { return }
                setHorizontalDragLive(tx)
            }
            .onEnded { value in
                handleStripDragEnded(translation: value.translation, width: w, height: h)
            }
    }

    private func handleStripDragEnded(translation: CGSize, width w: CGFloat, height h: CGFloat) {
        let tx = translation.width
        let ty = translation.height
        let axis = lockedDragAxis
        lockedDragAxis = nil

        guard page != .playbackSettings else {
            withAnimation(nowPlayingPanelSpring) {
                horizontalDrag = 0
            }
            return
        }

        guard let axis else {
            withAnimation(nowPlayingPanelSpring) {
                horizontalDrag = 0
            }
            return
        }

        if axis == .vertical {
            if page == .main {
                // Content scrolls down (finger moves up) → settings; content scrolls up (finger moves down) → album / dismiss.
                let progress = nowPlayingSettingsSheetProgress(dragTranslationY: settingsDragOffset, height: h)
                if nowPlayingSettingsSheetShouldOpen(progress: progress) {
                    withAnimation(nowPlayingPanelSpring) {
                        page = .playbackSettings
                        horizontalDrag = 0
                        settingsDragOffset = 0
                    }
                    return
                }
                if ty > 68 {
                    settingsDragOffset = 0
                    dismiss()
                    return
                }
                withAnimation(nowPlayingPanelSpring) {
                    settingsDragOffset = 0
                }
            }
            withAnimation(nowPlayingPanelSpring) {
                horizontalDrag = 0
            }
            return
        }

        let thresholdTowardsSide: CGFloat = w * 0.14
        let thresholdBackToMain: CGFloat = w * 0.12
        switch page {
        case .main:
            if tx < -thresholdTowardsSide {
                withAnimation(nowPlayingPanelSpring) {
                    page = .favourites
                    horizontalDrag = 0
                }
            } else if tx > thresholdTowardsSide {
                withAnimation(nowPlayingPanelSpring) {
                    page = .queue
                    horizontalDrag = 0
                }
            } else {
                withAnimation(nowPlayingPanelSpring) {
                    horizontalDrag = 0
                }
            }
        case .queue:
            if tx < -thresholdBackToMain {
                withAnimation(nowPlayingPanelSpring) {
                    page = .main
                    horizontalDrag = 0
                }
            } else {
                withAnimation(nowPlayingPanelSpring) {
                    horizontalDrag = 0
                }
            }
        case .favourites:
            if tx > thresholdBackToMain {
                withAnimation(nowPlayingPanelSpring) {
                    page = .main
                    horizontalDrag = 0
                }
            } else {
                withAnimation(nowPlayingPanelSpring) {
                    horizontalDrag = 0
                }
            }
        case .playbackSettings:
            break
        }
    }
}

// MARK: - Playing shell (isolates high-frequency player updates in child views)

private struct NowPlayingPlayingShell: View {
    let song: Song
    let artworkId: String
    let artworkURLString: String
    /// Two-way binding so the parent `NowPlayingView` can mirror the palette to
    /// its own full-screen ambient background layer.
    @Binding var palette: ArtworkPlaybackPalette?
    /// Combined inset for the floating toolbar + status-bar region (passed from parent
    /// GeometryReader so content is not obscured by the overlay buttons).
    var topInset: CGFloat = 0
    /// Home-indicator safe-area inset (passed from parent GeometryReader).
    var bottomInset: CGFloat = 0

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppModel.self) private var model

    private var accent: Color {
        palette?.accentColor ?? nowPlayingFallbackAccent
    }

    /// Source used for ambient-palette extraction: the official YouTube thumbnail while a YouTube
    /// track's embed video ID is known, otherwise the ordinary artwork URL. Keeps the ambient
    /// background in step with the on-screen video the same way local artwork drives it.
    private var paletteSourceURLString: String {
        if song.isYouTube, let videoID = model.player.currentYouTubeVideoID {
            return youtubeThumbnailURLString(videoID: videoID)
        }
        return artworkURLString
    }

    var body: some View {
        ZStack {
            // The ambient background for the full screen is rendered at the NowPlayingView
            // level (outside every .clipped() panel) and therefore covers the safe-area
            // regions as well.  No separate background is needed inside this ZStack.

            VStack(spacing: 0) {
                Spacer(minLength: topInset + (horizontalSizeClass == .regular ? 40 : 16))

                NowPlayingArtworkBlock(song: song, artworkId: artworkId, urlString: artworkURLString, accent: accent)
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
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())

                Spacer(minLength: 24)

                NowPlayingProgressSection(accent: accent)
                    .padding(.horizontal, 24)

                Spacer(minLength: 20)

                NowPlayingTransportSection(accent: accent)
                    .padding(.bottom, 8)

                Spacer(minLength: bottomInset + (horizontalSizeClass == .regular ? 48 : 24))
            }

            // Brief "スキップしました" toast for when an embed-restricted YouTube track
            // (`MusicPlayerService.scheduleAutoSkipAfterEmbedRestriction`) auto-advances the
            // queue. Deliberately at this shell level (not nested inside the YouTube error view)
            // so it stays visible across the transition onto whatever track plays next, including
            // a local file.
            if let skipped = model.player.youtubePlaybackJustSkippedMessage {
                VStack {
                    Text(skipped)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.top, topInset + 8)
                    Spacer()
                }
                .transition(.opacity)
                .animation(.easeInOut, value: model.player.youtubePlaybackJustSkippedMessage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: paletteSourceURLString) {
            let source = paletteSourceURLString
            guard let url = URL(string: source), !source.isEmpty else {
                palette = nil
                return
            }
            palette = await ArtworkPaletteExtractor.palette(forArtworkURL: url)
        }
    }
}

/// Standard-resolution official thumbnail for a YouTube video ID (`i.ytimg.com`), used both as the
/// loading-state placeholder behind the embed player and as the ambient-palette source so YouTube
/// tracks get the same colour-matched backdrop as local artwork.
func youtubeThumbnailURLString(videoID: String) -> String {
    "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
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
                        Task { model.player.seek(to: scrubValue) }
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
        HStack(spacing: 28) {
            transportIconButton(
                systemName: "shuffle",
                size: 18,
                frame: 44,
                tint: model.player.isShuffleEnabled ? accent : .white.opacity(0.55)
            ) {
                model.player.toggleShuffle()
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(model.player.isShuffleEnabled ? "On" : "Off")

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

            transportIconButton(
                systemName: model.player.repeatMode == .one ? "repeat.1" : "repeat",
                size: 18,
                frame: 44,
                tint: model.player.repeatMode == .off ? .white.opacity(0.55) : accent
            ) {
                model.player.cycleRepeatMode()
            }
            .accessibilityLabel("Repeat")
            .accessibilityValue(repeatModeAccessibilityValue)
        }
    }

    private var repeatModeAccessibilityValue: String {
        switch model.player.repeatMode {
        case .off: return String(localized: "Off")
        case .all: return String(localized: "Repeat all")
        case .one: return String(localized: "Repeat one")
        }
    }

    private func transportIconButton(systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        transportIconButton(systemName: systemName, size: size, frame: 56, tint: .white, action: action)
    }

    /// Shared pill styling for every transport control; `frame`/`tint` let the secondary
    /// shuffle/repeat buttons stay visually subordinate to previous/next while reusing the
    /// same shape language (translucent circle, semibold SF Symbol).
    private func transportIconButton(systemName: String, size: CGFloat, frame: CGFloat, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: frame, height: frame)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty state

private struct NowPlayingEmptyChrome: View {
    var body: some View {
        ZStack {
            // Background is handled by the outer NowPlayingAmbientBackground in NowPlayingView.
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Background

/// `internal` (not `private`) so the lyrics screen can share the same environmental glow.
struct NowPlayingAmbientBackground: View {
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
    let song: Song
    let artworkId: String
    let urlString: String
    let accent: Color

    @Environment(AppModel.self) private var model
    @State private var loaded: UIImage?

    private var taskIdentity: String { "\(artworkId)\u{1E}\(urlString)\u{1E}np" }

    var body: some View {
        Color.clear
            // YouTube tracks get a 16:9 video-shaped card; local tracks keep the classic square
            // jacket. Both share the same width cap so the card only changes height when the
            // song source switches, and that height change is animated below.
            .aspectRatio(song.isYouTube ? 16.0 / 9.0 : 1, contentMode: .fit)
            .frame(maxWidth: 340)
            .overlay {
                Group {
                    if song.isYouTube {
                        youtubeEmbedFill
                    } else {
                        artworkFill
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 32, y: 18)
            .shadow(color: accent.opacity(0.15), radius: 40, y: 12)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: song.isYouTube)
            .task(id: taskIdentity) {
                guard !song.isYouTube else { return }
                loaded = nil
                guard !urlString.isEmpty else { return }
                loaded = await RemoteArtworkImageLoader.loadUIImage(artworkId: artworkId, urlString: urlString)
            }
    }

    /// Official YouTube embed player, shown in place of jacket art while the current song is a
    /// YouTube library member (see `MusicPlayerService`'s YouTube backend). Reparents the single
    /// persistent `WKWebView` owned by `youtubePlaybackHost` into this screen while it is visible
    /// (see `YouTubeEmbedHostContainerView`) — dismissing Now Playing detaches it from display but
    /// does not stop it, so playback continues while browsing the Library, same as a local file.
    @ViewBuilder
    private var youtubeEmbedFill: some View {
        if let videoID = model.player.currentYouTubeVideoID {
            ZStack {
                // Shown immediately (no network round-trip needed for the embed itself) and kept
                // underneath the video so a slow embed handshake never shows a blank black square.
                youtubeThumbnail(videoID: videoID)
                YouTubeEmbedHostContainerView(webView: model.player.youtubePlaybackHost.webView)
                    .opacity(model.player.isPlaying ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: model.player.isPlaying)
            }
        } else if let error = model.player.youtubePlaybackErrorMessage {
            ZStack {
                Color.black
                VStack(spacing: 16) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                    if model.player.youtubePlaybackErrorFallback == .openInYouTubeApp {
                        Button {
                            model.player.openYouTubePlaybackErrorInYouTubeApp()
                        } label: {
                            Label("Open in YouTube", systemImage: "arrow.up.forward.app")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding(16)
            }
        } else {
            ZStack {
                Color.black
                ProgressView().tint(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder
    private var artworkFill: some View {
        if urlString.isEmpty {
            placeholder
        } else if let img = loaded {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                placeholder
                ProgressView()
                    .tint(.white.opacity(0.6))
            }
        }
    }

    /// Official YouTube thumbnail, shown behind the embed while it loads. Falls back to the same
    /// note-glyph placeholder as local artwork if the thumbnail itself fails to load.
    @ViewBuilder
    private func youtubeThumbnail(videoID: String) -> some View {
        if let url = URL(string: youtubeThumbnailURLString(videoID: videoID)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
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

// MARK: - Swipe side panels (queue left, favourites right, settings overlay)

private struct NowPlayingQueuePanel: View {
    @Binding var page: NowPlayingPage
    @Environment(AppModel.self) private var model
    var topInset: CGFloat = 0

    /// Drives `List`'s `.environment(\.editMode, _)`; the panel has no navigation bar of its
    /// own to host a standard `EditButton`, so the custom header below toggles this directly.
    @State private var editMode: EditMode = .inactive

    private var queue: [Song] {
        model.player.playbackQueue
    }

    /// Stable row identity for `ForEach`/`.onMove`. Plain `Array.indices` (as the read-only list
    /// used to use) breaks reorder/delete animations: every edit shifts the offsets — and hence
    /// the ids — of all subsequent rows, so SwiftUI can't tell they're the same row and tears down
    /// / rebuilds them instead of animating a clean move or delete (visible as old row content
    /// briefly flashing during the transition). `PlaybackQueueEditing.occurrenceIdentities` keys
    /// each row on its song id plus how many earlier queue entries share that id, which stays
    /// fixed across edits to *other* rows; only a duplicate of the same song shifts it.
    private struct QueueRow: Identifiable {
        let id: String
        let index: Int
        let song: Song
    }

    private var rows: [QueueRow] {
        let ids = PlaybackQueueEditing.occurrenceIdentities(for: queue.map(\.id))
        return queue.indices.map { offset in
            QueueRow(id: ids[offset], index: offset, song: queue[offset])
        }
    }

    /// Removes the queue row identified by `rowId`, looking its index up in the live queue at the
    /// moment the button is tapped rather than trusting the `row.index` captured when the context
    /// menu was built — the menu can stay open across a queue mutation triggered elsewhere, and an
    /// offset captured earlier could point at a different row by the time this runs.
    private func removeFromQueue(rowId: String) {
        let ids = PlaybackQueueEditing.occurrenceIdentities(for: queue.map(\.id))
        guard let index = ids.firstIndex(of: rowId) else { return }
        Task { await model.player.removeQueueItem(at: index) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up next")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                if !queue.isEmpty {
                    Button(editMode == .active ? "Done" : "Reorder") {
                        withAnimation(nowPlayingPanelSpring) {
                            editMode = editMode == .active ? .inactive : .active
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(nowPlayingFallbackAccent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, topInset + 4)
            .padding(.bottom, 8)
            List {
                if queue.isEmpty {
                    Text("The queue is empty.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { row in
                        Button {
                            Task {
                                await model.player.playQueueItem(at: row.index)
                                withAnimation(nowPlayingPanelSpring) {
                                    page = .main
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                if row.index == model.player.currentQueueIndex {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(nowPlayingFallbackAccent)
                                        .frame(width: 22)
                                } else {
                                    Text("\(row.index + 1)")
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 22)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.song.displayTitle)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(row.song.displayArtist)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.07, green: 0.07, blue: 0.08))
                                .padding(.horizontal, 8)
                        )
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            WatchTransferSongMenuItem(song: row.song)
                            Button(role: .destructive) {
                                removeFromQueue(rowId: row.id)
                            } label: {
                                Label("Remove from Queue", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        guard let from = offsets.first else { return }
                        let to = nowPlayingQueueMoveDestination(from: from, to: destination)
                        model.player.moveQueueItem(from: from, to: to)
                    }
                    // Row-level swipe-to-delete used to live here, but it fought the panel's own
                    // horizontal swipe-to-dismiss gesture (both read a horizontal drag on the same
                    // row). Removal now lives only in the context menu above.
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, $editMode)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            swipeHint("Swipe left for player")
                .padding(.bottom, 12)
        }
    }
}

private struct NowPlayingFavouritesPanel: View {
    @Binding var page: NowPlayingPage
    @Environment(AppModel.self) private var model
    var topInset: CGFloat = 0

    private var songs: [Song] {
        model.favouriteSongsForPlayback()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Favourites")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, topInset + 4)
                .padding(.bottom, 8)
            List {
                if songs.isEmpty {
                    Text("No favourites yet. Tap the heart on the player while a track is playing.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(songs) { song in
                        Button {
                            let list = model.favouriteSongsForPlayback()
                            Task {
                                await model.player.play(song, newQueue: list)
                                withAnimation(nowPlayingPanelSpring) {
                                    page = .main
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkImageView(
                                    artworkId: song.artworkId,
                                    urlString: model.artworkURL(for: song.artworkId),
                                    cornerRadius: 6,
                                    size: 44
                                )
                                .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.displayTitle)
                                        .font(.body.weight(.semibold))
                                    Text(song.displayArtist)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.07, green: 0.07, blue: 0.08))
                                .padding(.horizontal, 8)
                        )
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            WatchTransferSongMenuItem(song: song)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.removeFavourite(songId: song.id)
                            } label: {
                                Label("Remove", systemImage: "heart.slash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            swipeHint("Swipe right for player")
                .padding(.bottom, 12)
        }
    }
}

private struct NowPlayingPlaybackSettingsPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var page: NowPlayingPage
    var topInset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Playback")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, topInset + 4)
                .padding(.bottom, 8)
            List {
                // EQ has no effect on YouTube songs (audio comes from the embedded WKWebView, not
                // AVAudioEngine), so its controls are disabled instead of pretending they apply.
                let isYouTubeSong = model.player.currentSong?.isYouTube ?? false
                Section {
                    Toggle(
                        "Enable equaliser",
                        isOn: Binding(
                            get: { model.player.equaliserEnabled },
                            set: { model.player.setEqualiserEnabled($0) }
                        )
                    )
                    Menu {
                        ForEach(GraphicEqualiserConfiguration.presetNamesOrdered, id: \.self) { name in
                            Button(name) {
                                model.player.applyEqualiserPreset(named: name)
                            }
                        }
                    } label: {
                        HStack {
                            Text("Preset")
                            Spacer()
                            Text(model.player.equaliserPresetDisplayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Preamp")
                        Slider(
                            value: Binding(
                                get: { Double(model.player.equaliserPreampDecibels) },
                                set: { model.player.setEqualiserPreampDecibels(Float($0)) }
                            ),
                            in: -24 ... 24
                        )
                        .disabled(!model.player.equaliserEnabled)
                        Text("\(Int(model.player.equaliserPreampDecibels)) dB")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    GraphicEQView()
                        .listRowInsets(.init(top: 8, leading: 10, bottom: 8, trailing: 10))
                } header: {
                    Text("Equaliser")
                } footer: {
                    if isYouTubeSong {
                        Text("Not applied to YouTube playback.")
                    }
                }
                .disabled(isYouTubeSong)

                Section {
                    Toggle("Crossfade", isOn: .constant(false))
                        .disabled(true)
                    Toggle(
                        "Normalise loudness",
                        isOn: Binding(
                            get: { model.player.normaliseEnabled },
                            set: {
                                model.player.normaliseEnabled = $0
                                model.player.refreshVolumeForCurrentSong()
                            }
                        )
                    )
                } header: {
                    Text("Other")
                }

                Section {
                    Text("More audio options will appear here in a future update.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            swipeHint("Swipe down for player")
                .padding(.bottom, 12)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    let t = value.translation
                    guard t.height > 48, abs(t.height) > abs(t.width) else { return }
                    withAnimation(nowPlayingPanelSpring) {
                        page = .main
                    }
                }
        )
    }
}

// MARK: - EQ Curve Canvas

/// Pure display of the 10-band EQ frequency response as a polyline.
/// Positions are computed from the actual canvas size, so there is no fixed-offset drift.
private struct EQCurveCanvas: View {
    let decibels: [Float]
    var showLabels: Bool = true

    var body: some View {
        Canvas { context, size in
            drawCurve(context: context, size: size)
        }
    }

    private func drawCurve(context: GraphicsContext, size: CGSize) {
        let count = decibels.count
        guard count > 1 else { return }

        let leftInset: CGFloat = showLabels ? 28 : 4
        let topInset: CGFloat = 4
        let bottomInset: CGFloat = showLabels ? 18 : 4
        let plotW = size.width - leftInset
        let plotH = size.height - topInset - bottomInset

        func bandX(_ i: Int) -> CGFloat {
            leftInset + CGFloat(i) / CGFloat(count - 1) * plotW
        }
        func dbY(_ db: Double) -> CGFloat {
            topInset + (1.0 - (db + 24.0) / 48.0) * plotH
        }

        let zeroDby = dbY(0)
        let pts = decibels.indices.map { CGPoint(x: bandX($0), y: dbY(Double(decibels[$0]))) }

        // Horizontal grid lines every 6 dB (0 dB is more prominent)
        let gridDbs = stride(from: -24.0, through: 24.0, by: 6.0)
        for db in gridDbs {
            let y = dbY(db)
            var grid = Path()
            grid.move(to: CGPoint(x: leftInset, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
            let isZero = db == 0
            context.stroke(
                grid,
                with: .color(.white.opacity(isZero ? 0.28 : 0.10)),
                lineWidth: isZero ? 0.75 : 0.5
            )
        }

        // dB scale labels every 6 dB
        if showLabels {
            for db in gridDbs {
                let label = db > 0 ? "+\(Int(db))" : "\(Int(db))"
                context.draw(
                    Text(label)
                        .font(.system(size: 9, weight: db == 0 ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(db == 0 ? 0.75 : 0.45)),
                    at: CGPoint(x: leftInset - 4, y: dbY(db)),
                    anchor: .trailing
                )
            }
        }

        // Fill between polyline and 0 dB baseline
        var fill = Path()
        fill.move(to: CGPoint(x: pts[0].x, y: zeroDby))
        fill.addLine(to: pts[0])
        for i in 1 ..< count { fill.addLine(to: pts[i]) }
        fill.addLine(to: CGPoint(x: pts[count - 1].x, y: zeroDby))
        fill.closeSubpath()
        context.fill(fill, with: .color(.white.opacity(0.07)))

        // Polyline
        var line = Path()
        line.move(to: pts[0])
        for i in 1 ..< count { line.addLine(to: pts[i]) }
        context.stroke(line, with: .color(.white.opacity(0.7)), lineWidth: 1.5)

        // Band dots
        for pt in pts {
            let r: CGFloat = 2.5
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(0.9))
            )
        }

        // Frequency labels
        if showLabels {
            let labelY = size.height - bottomInset + 4
            for i in 0 ..< count {
                context.draw(
                    Text(EQCurveCanvas.freqLabel(i))
                        .font(.system(size: 8).weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.4)),
                    at: CGPoint(x: bandX(i), y: labelY),
                    anchor: .top
                )
            }
        }
    }

    static func freqLabel(_ index: Int) -> String {
        let hz = GraphicEqualiserConfiguration.centreFrequenciesHz[index]
        if hz >= 1000 {
            let k = hz / 1000
            return k.rounded() == k ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz))"
    }
}

// MARK: - Graphic EQ

/// Read-only graph row. Tap to open the band-adjustment sheet.
private struct GraphicEQView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdjustment = false

    var body: some View {
        Button { showAdjustment = true } label: {
            EQCurveCanvas(decibels: model.player.equaliserBandDecibels)
                .frame(height: 360)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(6)
                }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAdjustment) {
            EQAdjustmentSheet()
        }
    }
}

// MARK: - EQ Adjustment Sheet

private struct EQAdjustmentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private static let stepDb: Float = 1

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Live mini graph
                EQCurveCanvas(decibels: model.player.equaliserBandDecibels)
                    .frame(height: 192)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                Divider()

                // Band +/− controls
                HStack(spacing: 0) {
                    ForEach(0 ..< GraphicEqualiserConfiguration.bandCount, id: \.self) { i in
                        bandControl(index: i)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 20)

                Spacer()
            }
            .navigationTitle("Equaliser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Flat") { model.player.resetEqualiserToFlat() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func bandControl(index: Int) -> some View {
        let db = model.player.equaliserBandDecibels[index]
        let dbInt = Int(db)
        let enabled = model.player.equaliserEnabled

        VStack(spacing: 6) {
            RepeatButton(
                action: {
                    let current = model.player.equaliserBandDecibels[index]
                    model.player.setEqualiserBand(index: index, decibels: min(24, current + Self.stepDb))
                },
                isDisabled: {
                    model.player.equaliserBandDecibels[index] >= 24 || !model.player.equaliserEnabled
                }
            ) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        Color.accentColor.opacity(db >= 24 || !enabled ? 0.05 : 0.15),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }

            Text(dbInt >= 0 ? "+\(dbInt)" : "\(dbInt)")
                .font(.system(size: 11).monospacedDigit().weight(.medium))
                .foregroundStyle(dbInt == 0 ? .secondary : .primary)
                .frame(height: 16)

            Text(EQCurveCanvas.freqLabel(index))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 12)

            RepeatButton(
                action: {
                    let current = model.player.equaliserBandDecibels[index]
                    model.player.setEqualiserBand(index: index, decibels: max(-24, current - Self.stepDb))
                },
                isDisabled: {
                    model.player.equaliserBandDecibels[index] <= -24 || !model.player.equaliserEnabled
                }
            ) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        Color.accentColor.opacity(db <= -24 || !enabled ? 0.05 : 0.15),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Repeat Button

/// 押下直後に1回実行 → 0.4秒後に 0.08秒間隔で高速繰り返し。
/// - `action` / `isDisabled` はクロージャで毎回評価するため、
///   ビュー再構築前の古い値をキャプチャしてしまう stale closure 問題を回避。
private struct RepeatButton<Label: View>: View {
    let action: () -> Void
    let isDisabled: () -> Bool
    @ViewBuilder let label: () -> Label

    @State private var holdTimer: Timer?

    var body: some View {
        label()
            .contentShape(Rectangle())
            // onLongPressGesture の pressing: は押下開始/終了を確実に検知する
            .onLongPressGesture(
                minimumDuration: 60, // perform は事実上発火させない
                pressing: { isPressing in
                    if isPressing {
                        guard !isDisabled() else { return }
                        action()
                        // 0.4 秒後に高速繰り返し開始
                        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { timer in
                                guard !isDisabled() else {
                                    timer.invalidate()
                                    return
                                }
                                action()
                            }
                        }
                    } else {
                        holdTimer?.invalidate()
                        holdTimer = nil
                    }
                },
                perform: {}
            )
            .opacity(isDisabled() ? 0.35 : 1.0)
    }
}

// MARK: -

private func swipeHint(_ text: String) -> some View {
    Text(text)
        .font(.caption2)
        .foregroundStyle(.tertiary)
}
