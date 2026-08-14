import SwiftUI

/// Fullscreen "sidecar" now-playing display, pushed by the paired Mac (`sidecar.active` in
/// `/v1/remote/state`, parsed by `SidecarDirective`). Display-only — playback stays on the
/// desktop; `AppModel`'s sidecar poller keeps `sidecarTitle`/`sidecarPosition`/… fresh while this
/// screen is presented. Landscape-first (the screen forces landscape while presented — see
/// `SidecarOrientationPolicy`): large artwork on the leading side, synced lyrics on the trailing
/// side, a thin progress bar along the bottom. The close button and time labels fade out after a
/// few seconds of inactivity for an "idle elegance" ambient look (`SidecarChromeVisibilityPolicy`);
/// any tap brings them back.
struct SidecarScreen: View {
    @Environment(AppModel.self) private var model
    @State private var lyricsLines: [LRCParser.TimedLine] = []
    @State private var lyricsPlainText: String?
    @State private var lyricsLoadedForSongId: String?
    @State private var lastInteraction = Date()
    /// Stable anchor for `progressBar`'s `TimelineView(.periodic(from:by:))`. MUST NOT be `.now`
    /// evaluated fresh inside `progressBar`'s body: `progressBar`'s own tick writes `chromeNow`
    /// (via `.onChange(of: context.date)`), which `chromeVisible` reads, which the close button's
    /// `.opacity(chromeVisible ? 1 : 0)` reads — so every tick forces `SidecarScreen.body` to
    /// re-evaluate and reconstruct a brand-new `TimelineView` value. A schedule anchored at `.now`
    /// re-evaluated on every reconstruction has no settled cadence: each fresh instance's first
    /// entry fires immediately, which writes `chromeNow` again, which reconstructs again — an
    /// unbounded feedback loop that pegs the main thread at ~100% and (empirically, see
    /// `progress/sidecar-poll-tick-cpu-leak.md` round 3) storms
    /// `BLSInvalidateFrameSpecifiersAction` at tens of thousands of events/sec while the sidecar
    /// is presented. Anchoring at a `@State` value fixed once (at this view's first construction)
    /// keeps the schedule's entries deterministic across reconstructions, so it settles into the
    /// intended 0.25s cadence instead of restarting every tick.
    @State private var progressScheduleAnchor = Date()
    /// Extracted (at most once per artwork change — see the `.task(id:)` below) from the current
    /// track's artwork, feeding `SidecarAmbientBackground`'s Desktop-matched gradient. `nil` while
    /// unresolved (no explicit `artworkId` on the sidecar directive) or before the first extraction
    /// completes, in which case the background falls back to a fixed near-black gradient.
    @State private var ambientPalette: ArtworkPlaybackPalette?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            SidecarAmbientBackground(palette: ambientPalette)
                .ignoresSafeArea(.all)
                .animation(.easeInOut(duration: SidecarBackgroundGradient.transitionDuration), value: ambientPalette)

            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height
                Group {
                    if isLandscape {
                        HStack(alignment: .center, spacing: 40) {
                            artworkAndInfo
                                .frame(maxWidth: geo.size.width * 0.4, maxHeight: .infinity)
                            lyricsPane
                        }
                    } else {
                        VStack(spacing: 24) {
                            artworkAndInfo
                            lyricsPane
                        }
                    }
                }
                .padding(32)
                // Leaves room at the bottom for the edge-pinned `progressBar` below so the
                // vertically-centred artwork/text block never grows tall enough to collide with
                // it (the original bug behind complaint #2 — the seek bar visually landing between
                // the artist and album labels when the centred content block was tall).
                .padding(.bottom, 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack {
                Spacer()
                progressBar
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
            }

            NowPlayingNavIconButton(
                action: { model.dismissSidecarLocally() },
                accessibilityLabel: String(localized: "Close")
            ) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .opacity(chromeVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.4), value: chromeVisible)
        }
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .onTapGesture { lastInteraction = Date() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            applyOrientation(sidecarPresented: true)
            lastInteraction = Date()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            applyOrientation(sidecarPresented: false)
        }
        .task(id: model.sidecarSongId) {
            await reloadLyricsIfNeeded()
        }
        .task(id: model.sidecarArtworkId) {
            await reloadAmbientPaletteIfNeeded()
        }
    }

    // MARK: - Ambient background

    /// Resolves and caches the artwork palette feeding `SidecarAmbientBackground`. Only keyed off
    /// `model.sidecarArtworkId` (the directive's explicit artwork id) rather than duplicating
    /// `SidecarArtworkView`'s fuzzy title/artist library match — the fuzzy-match path is a
    /// secondary fallback (no `artworkId` in `/v1/remote/state`), and the ambient background simply
    /// stays at its default near-black gradient in that case rather than every view independently
    /// re-deriving the resolved id.
    private func reloadAmbientPaletteIfNeeded() async {
        guard let artworkId = model.sidecarArtworkId, !artworkId.isEmpty else {
            ambientPalette = nil
            return
        }
        let urlString = model.artworkURL(for: artworkId)
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            ambientPalette = nil
            return
        }
        ambientPalette = await ArtworkPaletteExtractor.palette(forArtworkURL: url)
    }

    // MARK: - Idle chrome visibility

    /// `TimelineView` isn't available for a plain computed property, so this samples "now" only via
    /// `progressBar`/`lyricsPane`'s own periodic ticks; the close button reuses the same
    /// `lastInteraction` state and re-renders whenever a tap updates it or the periodic tick below
    /// forces a body re-evaluation.
    private var chromeVisible: Bool {
        SidecarChromeVisibilityPolicy.isVisible(lastInteraction: lastInteraction, now: chromeNow)
    }

    @State private var chromeNow = Date()

    // MARK: - Orientation

    /// Forces landscape while this screen is on screen, restoring the app's normal `.all` mask on
    /// dismiss (see `SidecarOrientationPolicy`, `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`).
    private func applyOrientation(sidecarPresented: Bool) {
        SidecarOrientationLock.current = SidecarOrientationPolicy.mask(
            sidecarPresented: sidecarPresented,
            defaultMask: SidecarOrientationLock.defaultMask
        )
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }
        if sidecarPresented {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        } else {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .all)) { _ in }
        }
        scene.windows.first(where: \.isKeyWindow)?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    // MARK: - Artwork + track info

    private var artworkAndInfo: some View {
        VStack(spacing: 20) {
            // `GeometryReader` here (rather than `.aspectRatio(1, contentMode: .fit)` directly on
            // the artwork) is what fixes the black-letterboxing-bars bug: `.aspectRatio(.fit)`
            // depends on the *proposed* size already being close to square, but this column's
            // proposed box is however tall the HStack row happens to be (which, unconstrained,
            // does not equal `min(width, height)`). Computing an explicit square side
            // (`SidecarArtworkLayout.squareSide`) from the column's actual measured bounds and
            // applying it as a hard `.frame(width:height:)` guarantees a true square regardless of
            // the column's own aspect ratio or the underlying artwork image's aspect ratio (the
            // `ArtworkImageView` inside always fills via `.aspectRatio(contentMode: .fill)`).
            GeometryReader { geo in
                let side = SidecarArtworkLayout.squareSide(
                    columnWidth: geo.size.width,
                    columnHeight: geo.size.height,
                    margin: 12,
                    maxSide: 420
                )
                SidecarArtworkView(songId: model.sidecarSongId, artworkId: model.sidecarArtworkId, title: model.sidecarTitle, artist: model.sidecarArtist)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 36, y: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack(spacing: 6) {
                Text(model.sidecarTitle.isEmpty ? String(localized: "No track") : model.sidecarTitle)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Text(model.sidecarArtist)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                if !model.sidecarAlbum.isEmpty {
                    Text(model.sidecarAlbum)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Lyrics

    @ViewBuilder
    private var lyricsPane: some View {
        if !lyricsLines.isEmpty {
            SidecarSyncedLyricsList(lines: lyricsLines)
        } else if let plain = lyricsPlainText, !plain.isEmpty {
            ScrollView {
                Text(plain)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "music.note")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.22))
                Text(String(localized: "No Lyrics"))
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reloadLyricsIfNeeded() async {
        guard let songId = model.sidecarSongId, !songId.isEmpty, lyricsLoadedForSongId != songId else {
            if model.sidecarSongId == nil {
                lyricsLines = []
                lyricsPlainText = nil
                lyricsLoadedForSongId = nil
            }
            return
        }
        lyricsLoadedForSongId = songId
        lyricsLines = []
        lyricsPlainText = nil
        do {
            let payload = try await model.withFailover { try await $0.fetchLyrics(songId: songId) }
            guard payload.found, let content = payload.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                return
            }
            if payload.type == "lrc" {
                let timed = LRCParser.parseTimedLines(content)
                if !timed.isEmpty {
                    lyricsLines = timed
                    return
                }
            }
            lyricsPlainText = content
        } catch {
            // Lyrics are optional for the sidecar display; leave the "No Lyrics" placeholder.
        }
    }

    // MARK: - Progress

    /// A thin full-width capsule pinned near the screen's bottom edge (see `body`'s outer
    /// `VStack { Spacer(); progressBar }`), with the elapsed/remaining monospaced time labels
    /// inline at its two ends rather than stacked underneath — "シークバーを画面の端っこに配置".
    /// The capsule itself always stays visible (per `SidecarChromeVisibilityPolicy`'s existing
    /// "idle elegance" behaviour); only the two time labels fold into the chrome fade.
    private var progressBar: some View {
        TimelineView(.periodic(from: progressScheduleAnchor, by: 0.25)) { context in
            let interpolated = SidecarProgressInterpolation.interpolatedPosition(
                position: model.sidecarPosition,
                timestamp: model.sidecarPositionTimestamp,
                playing: model.sidecarPlaying,
                now: context.date,
                duration: model.sidecarDuration
            )
            let labelsVisible = SidecarChromeVisibilityPolicy.isVisible(lastInteraction: lastInteraction, now: context.date)
            let fraction = model.sidecarDuration > 0 ? min(1, max(0, interpolated / model.sidecarDuration)) : 0

            HStack(spacing: 10) {
                Text(sidecarFormatTime(interpolated))
                    .opacity(labelsVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: labelsVisible)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(.white.opacity(0.7))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 3)

                Text(sidecarFormatTime(max(0, model.sidecarDuration - interpolated)))
                    .opacity(labelsVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: labelsVisible)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
            .onChange(of: context.date) { _, newDate in
                chromeNow = newDate
            }
        }
    }
}

private func sidecarFormatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return "\(m):\(String(format: "%02d", s))"
}

/// Ported from Desktop's fullscreen overlay background (`src/renderer/styles/components.css:1764-
/// 1776`, `.fs-overlay`): a 135°-diagonal two-stop linear gradient between the artwork's two
/// dominant colours, each mixed 30% into a near-black `#0e0e1a` base
/// (`SidecarBackgroundGradient.mixedStop`). `.topLeading`/`.bottomTrailing` approximates CSS's
/// 135deg direction (down-and-right diagonal) — SwiftUI's `LinearGradient` has no raw degree API.
/// Falls back to a fixed near-black gradient (rather than the old `NowPlayingAmbientBackground`
/// pink/blue default) when no palette has been extracted yet, matching Desktop's
/// `setDefaultColors()` fallback being *dark*, not brand-coloured, before the first extraction.
private struct SidecarAmbientBackground: View {
    let palette: ArtworkPlaybackPalette?

    private static let fallbackBase = Color(red: 14.0 / 255.0, green: 14.0 / 255.0, blue: 26.0 / 255.0)

    var body: some View {
        LinearGradient(
            colors: [stop1, stop2],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var stop1: Color {
        guard let palette else { return Self.fallbackBase }
        let mixed = SidecarBackgroundGradient.mixedStop(from: palette.swatch1)
        return Color(red: mixed.0, green: mixed.1, blue: mixed.2)
    }

    private var stop2: Color {
        guard let palette else { return Self.fallbackBase }
        let mixed = SidecarBackgroundGradient.mixedStop(from: palette.swatch2)
        return Color(red: mixed.0, green: mixed.1, blue: mixed.2)
    }
}

/// Resolves the sidecar's artwork: uses `artworkId` directly when the directive supplied one,
/// otherwise falls back to fuzzy title/artist matching against the Remote library — mirroring
/// `RemoteControlScreen.RemoteArtworkCard`, which has no `artworkId` in `/v1/remote/state` to work with.
private struct SidecarArtworkView: View {
    @Environment(AppModel.self) private var model
    let songId: String?
    let artworkId: String?
    let title: String
    let artist: String

    private var resolvedArtworkId: String? {
        if let artworkId, !artworkId.isEmpty { return artworkId }
        guard case .loaded(let songs) = model.libraryState else { return nil }
        if let songId, !songId.isEmpty, let matched = songs.first(where: { $0.id == songId }), !matched.artworkId.isEmpty {
            return matched.artworkId
        }
        guard !title.isEmpty else { return nil }
        let matched = songs.first { $0.title == title && $0.artist == artist } ?? songs.first { $0.title == title }
        guard let matched, !matched.artworkId.isEmpty else { return nil }
        return matched.artworkId
    }

    var body: some View {
        Group {
            if let id = resolvedArtworkId {
                ArtworkImageView(artworkId: id, urlString: model.artworkURL(for: id), cornerRadius: 0, size: nil)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.14), Color(white: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "hifispeaker.2.fill")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.28))
                }
            }
        }
        .task {
            if case .idle = model.libraryState {
                await model.refreshLibrary()
            }
        }
    }
}

/// Simple synced-lyrics list for the sidecar (a plain scrolling highlight, not the full cascade
/// motion `NowPlayingSyncedLyricsScroll` uses — that type is private to
/// `NowPlayingLyricsScreen.swift`, so this reuses its underlying `LRCParser` data/active-line logic
/// rather than duplicating the motion system for a secondary, glanceable display). The active line
/// is full-opacity/larger/bold; neighbouring lines dim further the more lines away from active they
/// are, so the eye is drawn to the current lyric without the rest of the pane feeling empty.
/// Collects each line's own (unscaled, pre-transform) rendered height, keyed by index — mirrors
/// Desktop's `cachedLrcHeights` (`fullscreen-view.ts`'s `applyLyricsMotion`), which measures each
/// `<p>`'s `getBoundingClientRect().height` once and reuses it for the cumulative layout sum.
private struct SidecarLineHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Renders lyric lines exactly like Desktop's fullscreen LRC pane
/// (`.fs-lyrics-inner.fs-lrc`, `components.css:2137-2162`, driven by `applyLyricsMotion` in
/// `fullscreen-view.ts:392-426`): **each line moves independently**, absolutely positioned by its
/// own animated `y` offset, rather than the whole list being scrolled as one unit. The active line
/// is anchored at `paneHeight * ANCHOR_RATIO` (`SidecarLyricsLayout.anchorRatio`); every other line
/// stacks above/below it via a running sum of `height + interBlockGap` — computed by
/// `SidecarLyricsLayout.tops`, ported 1:1 from `applyLyricsMotion`. Each line's transform animates
/// over `MOTION_DURATION_MS` with a `dist * MOTION_DELAY_STEP_MS` start delay, using CSS's default
/// `ease` timing function (`cubic-bezier(0.25, 0.1, 0.25, 1.0)` — Desktop sets no
/// `transition-timing-function`, so the UA default applies), matching `components.css:2154-2156`'s
/// `transition-property: transform, opacity, color`.
///
/// Styling is intentionally minimal — only what `components.css:2143-2162` actually specifies:
/// bold weight on every line (Desktop never swaps weight), colour `rgba(255,255,255,0.45)` inactive
/// vs `#fff` active (a flat two-state swap, no distance-based opacity falloff — Desktop has none),
/// `scale(1.091)` from the leading edge on the active line only, and its `text-shadow: 0 0 24px
/// rgba(255,255,255,0.15)` glow. No previous port's extra embellishments survive here.
private struct SidecarSyncedLyricsList: View {
    @Environment(AppModel.self) private var model
    let lines: [LRCParser.TimedLine]

    /// `-1` means "nothing active yet" (before the first line's timestamp — see
    /// `SidecarLyricsMotionPolicy.activeIndex`), matching Desktop's `applyLyricsMotion(-1, true)`
    /// initial state. Updated at most once per actual line change (`SidecarActiveLineUpdatePolicy`)
    /// rather than on every 0.2s tick, so this view only re-diffs when the highlighted line
    /// genuinely moves instead of 5x/sec for as long as the sidecar screen is on screen.
    @State private var activeIndex = -1
    /// Stable anchor for the `TimelineView` below — see `SidecarScreen.progressScheduleAnchor`'s
    /// doc comment for why `.now` (re-evaluated on every reconstruction) is unsafe whenever the
    /// tick can write `@State` that this view itself reads (here, `activeIndex` via
    /// `SidecarActiveLineUpdatePolicy`-gated writes). The gate limits the blast radius to one
    /// reconstruction per genuine line change rather than an unbounded loop, but a fixed anchor
    /// removes the footgun entirely.
    @State private var lyricsScheduleAnchor = Date()
    /// Per-line measured heights (index → height), fed by `SidecarLineHeightKey`. Missing entries
    /// (not yet measured, e.g. a line never rendered because it's far outside the viewport margin)
    /// fall back to `Self.fallbackLineHeight` for the layout sum — same "reuse a placeholder until
    /// measured" approach as Desktop's `cachedLrcHeights`.
    @State private var lineHeights: [Int: CGFloat] = [:]

    /// Placeholder height used for any line not yet measured, so far-off lines can still be slotted
    /// into the cumulative layout before they've ever been rendered once.
    private static let fallbackLineHeight: CGFloat = 44
    /// Lines whose computed `y` falls further than this outside the pane's `[0, paneHeight]` range
    /// are skipped entirely, bounding the number of live views/animations to roughly what's visible
    /// (plus a small margin for lines animating into frame) instead of the whole song.
    private static let renderMargin: CGFloat = 400
    /// CSS's default `transition-timing-function: ease` (Desktop sets no explicit timing function
    /// on `.fs-lyrics-inner.fs-lrc p`, so the UA default `ease` applies).
    private static let easing = (0.25, 0.1, 0.25, 1.0)

    var body: some View {
        GeometryReader { paneGeo in
            let paneHeight = paneGeo.size.height
            let heights = (0..<lines.count).map { lineHeights[$0] ?? Self.fallbackLineHeight }
            let baseIndex = lines.isEmpty ? 0 : min(max(0, activeIndex), lines.count - 1)
            let tops = SidecarLyricsLayout.tops(heights: heights, baseIndex: baseIndex, paneHeight: paneHeight)

            ZStack(alignment: .topLeading) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    let y = index < tops.count ? tops[index] : 0
                    if y > -Self.renderMargin && y < paneHeight + Self.renderMargin {
                        let isActive = index == activeIndex
                        let distance = abs(index - baseIndex)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(isActive ? 1 : 0.45))
                            .shadow(color: .white.opacity(isActive ? 0.15 : 0), radius: isActive ? 24 : 0)
                            .frame(width: paneGeo.size.width / SidecarLyricsMotionPolicy.activeLineScale, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .scaleEffect(isActive ? SidecarLyricsMotionPolicy.activeLineScale : 1, anchor: .leading)
                            .offset(y: y)
                            .animation(
                                .timingCurve(Self.easing.0, Self.easing.1, Self.easing.2, Self.easing.3, duration: SidecarLyricsMotionPolicy.duration)
                                    .delay(SidecarLyricsMotionPolicy.staggerDelay(forDistance: distance)),
                                value: y
                            )
                            .background(
                                GeometryReader { lineGeo in
                                    Color.clear.preference(key: SidecarLineHeightKey.self, value: [index: lineGeo.size.height])
                                }
                            )
                    }
                }
            }
            .onPreferenceChange(SidecarLineHeightKey.self) { newHeights in
                lineHeights.merge(newHeights) { _, new in new }
            }
        }
        .background(
            TimelineView(.periodic(from: lyricsScheduleAnchor, by: 0.2)) { context in
                Color.clear
                    .task(id: context.date) {
                        let interpolated = SidecarProgressInterpolation.interpolatedPosition(
                            position: model.sidecarPosition,
                            timestamp: model.sidecarPositionTimestamp,
                            playing: model.sidecarPlaying,
                            now: context.date,
                            duration: model.sidecarDuration
                        )
                        let newActive = SidecarLyricsMotionPolicy.activeIndex(in: lines, at: interpolated)
                        if SidecarActiveLineUpdatePolicy.shouldUpdate(currentIndex: activeIndex, newIndex: newActive) {
                            activeIndex = newActive
                        }
                    }
            }
        )
    }
}
