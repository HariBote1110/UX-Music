import SwiftUI
import UIKit

/// Full-screen Now Playing (`markdown/appletv-servermode-plan.md` Phase 2). Large artwork, track
/// info, progress, and Siri Remote transport controls, plus synced lyrics (falling back to an
/// artwork-centric layout for songs without lyrics) and an ambient (idle) presentation after a
/// period of no remote interaction — which dims the chrome away but deliberately keeps the artwork
/// and lyrics on screen, see `TVAmbientPresentation`. Media-key handling itself (play/pause/next/previous from the physical
/// remote, Control Centre, etc.) already comes for free from `MusicPlayerService`'s existing
/// `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter` wiring, which is shared unmodified with
/// iOS/watchOS — see `progress/tvos-nowplaying.md` for why no TV-specific seam was needed there.
struct TVNowPlayingView: View {
    let player: MusicPlayerService
    let client: RemoteAPIClient

    @Environment(\.dismiss) private var dismiss
    /// Timed lines, each optionally paired with its 和訳 — see `SidecarLyricsTranslationMerge`.
    /// `translation == nil` on every line renders identically to the original single-language pane.
    @State private var lyricsLines: [TranslatedTimedLine] = []
    @State private var lastInteractionAt = Date()
    @State private var ambientState: TVAmbientStateMachine.State = .normal
    /// When the current ambient stretch began, driving `TVAmbientPresentation.driftOffset`'s phase.
    /// `nil` while normal.
    @State private var ambientSince: Date?
    /// Stable anchor for the idle-tick `TimelineView` below. MUST NOT be `.now` evaluated inside the
    /// body: this tick writes `@State` (`ambientState`/`ambientSince`) that the body itself reads, so
    /// every tick reconstructs the `TimelineView`; a schedule re-anchored at a fresh `.now` on each
    /// reconstruction fires its first entry immediately, writes again, and reconstructs again — the
    /// unbounded feedback loop documented in `progress/sidecar-poll-tick-cpu-leak.md`. Anchoring at a
    /// `@State` value fixed once keeps the entries deterministic, so it settles into the intended 1s
    /// cadence.
    @State private var tickAnchor = Date()

    var body: some View {
        TimelineView(.periodic(from: tickAnchor, by: 1)) { context in
            let idleSeconds = context.date.timeIntervalSince(lastInteractionAt)
            let resolved = TVAmbientStateMachine.next(
                current: ambientState,
                isPlaying: player.isPlaying,
                secondsSinceLastInteraction: idleSeconds
            )
            let drift = TVAmbientPresentation.driftOffset(
                ambient: resolved == .ambient,
                secondsSinceAmbientStart: context.date.timeIntervalSince(ambientSince ?? context.date)
            )

            content(ambient: resolved == .ambient, drift: drift)
                .onChange(of: resolved) { _, newValue in
                    ambientState = newValue
                    ambientSince = newValue == .ambient ? Date() : nil
                }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = player.isPlaying }
        .onChange(of: player.isPlaying) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task(id: player.currentSong?.id) { await loadLyrics() }
        .onMoveCommand { _ in registerInteraction() }
        .onTapGesture { registerInteraction() }
        .onExitCommand { handleExitCommand() }
        .background(TVDesignTokens.charcoalBase.ignoresSafeArea())
    }

    /// Ambient does NOT swap the layout out any more — see `TVAmbientPresentation` for the defect
    /// that behaviour caused (30s idle left nothing but the background wash). The same artwork/
    /// lyrics layout stays mounted; it only dims, loses its chrome, and drifts slowly.
    ///
    /// The screen size is measured **once**, here, by a `GeometryReader` that is NOT itself a
    /// descendant of the `.opacity`/`.offset`/`.animation` chain applied to the stage below (see
    /// `progress/tvos-nowplaying-fullscreen-shift.md`). `TVNowPlayingStageLayout` used to own its
    /// *own* `GeometryReader` nested inside that animated, drift-offset subtree; mid-transition
    /// (confirmed by `NSLog`-instrumented reproduction: the moment lyrics finish loading and
    /// `hasLyrics` flips, i.e. exactly the real-flow symptom, never the static DEBUG harness) that
    /// inner reader intermittently self-reported a bogus **square** size (`1760×1760` against a
    /// correct `1760×960` proposal from this very function, logged in the same frame) — SwiftUI
    /// occasionally hands a `GeometryReader` a stale/ghost proposal when it sits inside a view that
    /// an implicit `.animation()` is mid-interpolating. The stage's `ZStack` parent then centred
    /// that oversized child, shoving its top ~300pt above y=0 — the reported "刺さる"/vanished-chrome
    /// defect. Threading the one trustworthy measurement down as a plain value, instead of
    /// re-measuring inside the animated subtree, removes the only place that ghost value could ever
    /// originate.
    @ViewBuilder
    private func content(ambient: Bool, drift: CGSize) -> some View {
        GeometryReader { screenGeo in
            ZStack(alignment: .top) {
                // Backgrounds MUST NOT share the CONTENT stage's bounded frame/`.clipped()` below —
                // `screenGeo.size` is the safe-area-*excluded* proposal (e.g. 1760×960 on a
                // 1920×1080 canvas), so constraining the backgrounds to it left visible black bands
                // on all four edges. `.ignoresSafeArea()` here lets each background paint edge to
                // edge on the physical canvas while only the content stage below respects the safe
                // area's bounded frame.
                TVCinematicBackground(breathing: ambient)
                    .ignoresSafeArea()
                TVNowPlayingAmbientBackground(artworkId: player.currentSong?.artworkId ?? "", client: client, ambient: ambient)
                    .ignoresSafeArea()

                TVNowPlayingStageLayout(player: player, client: client, lines: lyricsLines, ambient: ambient, screenSize: screenGeo.size)
                    .opacity(TVAmbientPresentation.contentOpacity(ambient: ambient))
                    .offset(x: drift.width, y: drift.height)
                    .animation(.linear(duration: 1), value: drift)
                    // Belt-and-braces backstop, not the primary fix: even a mis-measured/oversized
                    // child can no longer drag the CONTENT off the top of the screen, because `.top`
                    // alignment (not the ZStack default `.center`) pins its origin to y=0 and
                    // `.clipped()` hard-stops anything that still overflows. Scoped to the stage only
                    // — NOT the backgrounds above — so this can never reproduce the letterboxing bug.
                    .frame(width: screenGeo.size.width, height: screenGeo.size.height, alignment: .top)
                    .clipped()
            }
            .animation(.easeInOut(duration: TVAmbientPresentation.transitionDuration), value: ambient)
        }
    }

    private func registerInteraction() {
        lastInteractionAt = .now
        ambientState = .normal
        ambientSince = nil
    }

    /// Menu/Back handler: two-step exit driven by `TVAmbientStateMachine.exitCommand` (pure, unit
    /// tested). While the ambient presentation is up, Menu only wakes the screen back to normal — it
    /// must NOT also dismiss in the same press, or a quick double-press of Menu would fall through
    /// the dismissed `fullScreenCover` straight to the tvOS home screen. Only a Menu press while
    /// already showing the normal layout dismisses back to browse; playback is untouched either way
    /// (see `MusicPlayerService`, which lives above this view).
    private func handleExitCommand() {
        switch TVAmbientStateMachine.exitCommand(current: ambientState) {
        case .returnToNormal:
            registerInteraction()
        case .dismissScreen:
            dismiss()
        }
    }

    /// Fetches `/v1/remote/lyrics` for the current song and parses synced (`.lrc`) content only —
    /// plain-text lyrics have no timestamps to drive a current-line highlight on a 10-foot display,
    /// so (per the Phase 2 plan) songs without *synced* lyrics fall back to the artwork-centric
    /// layout exactly as if they had no lyrics at all. Any 和訳 the desktop has saved for the track
    /// arrives on the same payload and is paired in by `SidecarLyricsTranslationMerge`, the same
    /// helper the Sidecar screen uses.
    private func loadLyrics() async {
        // Clear synchronously BEFORE the fetch, not just on failure/not-found: without this, the
        // PREVIOUS song's lyric lines stayed visible (with the NEW song's already-reset
        // `positionSeconds`) for the whole in-flight window of this `await` — see
        // `TVNowPlayingStageLayout`'s `.top`-alignment doc comment for the layout symptom this
        // mismatch caused.
        lyricsLines = []
        guard let song = player.currentSong else { return }
        do {
            let payload = try await client.fetchLyrics(songId: song.id)
            guard payload.found, payload.type == "lrc", let raw = payload.content else {
                lyricsLines = []
                return
            }
            lyricsLines = SidecarLyricsTranslationMerge.merge(
                primary: LRCParser.parseTimedLines(raw),
                translationContent: payload.translationContent,
                translationFormat: payload.translationFormat
            )
        } catch {
            lyricsLines = []
        }
    }
}

/// Faint, slowly drifting artwork wash layered *under* the signature pink/blue light pools
/// (`TVCinematicBackground`) so the current song's dominant colours tint the scene without a full
/// colour-extraction pipeline — see `progress/tvos-design.md` "artwork-tint decision" for why v1
/// blends a low-opacity blurred artwork wash rather than sampling pixel colours. Recedes further
/// (lower opacity, more blur) in ambient mode per the design brief.
private struct TVNowPlayingAmbientBackground: View {
    let artworkId: String
    let client: RemoteAPIClient
    var ambient: Bool = false
    @State private var driftUp = false

    var body: some View {
        TVArtworkImage(artworkId: artworkId, client: client)
            .scaleEffect(driftUp ? 1.12 : 1.0)
            .blur(radius: ambient ? 90 : 70)
            .opacity(ambient ? 0.18 : 0.3)
            .blendMode(.plusLighter)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 1.2), value: ambient)
            .onAppear {
                withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                    driftUp = true
                }
            }
    }
}

/// Large artwork card: rounded corners with a subtle pink-tinted glow shadow per the cinematic
/// design (`progress/tvos-design.md`), used for songs without synced lyrics.
private struct TVCinematicArtworkCard: View {
    let artworkId: String
    let client: RemoteAPIClient
    let size: CGFloat

    var body: some View {
        TVArtworkImage(artworkId: artworkId, client: client)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: TVDesignTokens.signaturePink.opacity(0.25), radius: 36, y: 12)
    }
}

/// Single stage layout for the Now Playing screen — one `HStack(alignment: .top)` container that
/// stays mounted whether or not lyrics are loaded, so the artwork's identity never swaps trees
/// mid-playback. Previously the screen picked between two structurally different view trees
/// (a centred `VStack` for songs without lyrics vs. this `GeometryReader`/`HStack` for songs with
/// them); because that swap happened async (lyrics load via `.task(id:)`) and carried no
/// `.transition()`, the ZStack-level ambient `.animation(...)` in `TVNowPlayingView.content(_:_:)`
/// could capture it and interpolate the artwork from centred-560 to top-leading-420 — the reported
/// "ジャケットが画面に突き刺さる" defect (`progress/tvos-nowplaying-artwork-stab.md`). That fix still
/// let the artwork/left-column geometry itself vary with `hasLyrics` (560→420, animated); a later
/// pass found the animated resize just as jarring — the artwork visibly glides left the moment
/// lyrics finish loading mid-playback (`progress/tvos-nowplaying-fixed-geometry.md`). The left
/// column's width and the artwork's size are now CONSTANT — fixed the moment this view appears,
/// independent of `hasLyrics` — so nothing in the artwork/title/artist/transport column can ever
/// move once mounted. Lyrics presence only swaps in the right-hand lyrics stage behind a
/// `.transition(.opacity)`; it never touches the left column's geometry.
private struct TVNowPlayingStageLayout: View {
    let player: MusicPlayerService
    let client: RemoteAPIClient
    let lines: [TranslatedTimedLine]
    var ambient: Bool = false
    /// The screen size, measured exactly once by `TVNowPlayingView.content(ambient:drift:)`'s own
    /// `GeometryReader` and threaded down as a plain value — see that function's doc comment for why
    /// this view must NOT re-measure with a `GeometryReader` of its own: nested inside the
    /// `.opacity`/`.offset`/`.animation` chain applied to this view at its call site, a self-owned
    /// reader intermittently self-reported a bogus size during the lyrics-load transition, which is
    /// exactly the "content shifted ~300pt up" defect reported from the real app.
    let screenSize: CGSize

    private var hasLyrics: Bool { !lines.isEmpty }
    /// Fixed regardless of `hasLyrics` — see this type's doc comment. 480pt was chosen by visual
    /// judgement on the 1920×1080 harnesses as the size that reads well both in the artwork-only
    /// layout (previously 560pt) and beside the lyrics pane (previously 420pt): small enough to
    /// leave the lyrics stage comfortable room, large enough not to look shrunken when lyrics are
    /// absent.
    private static let artworkSize: CGFloat = 480
    /// Left column width — wider than `artworkSize` so the title/artist labels (and the transport
    /// row/progress bar) have room without wrapping against the artwork's own edge, mirroring the
    /// iOS Sidecar screen's `SidecarLayoutSpacing.artworkColumnWidthFraction` column being wider
    /// than the artwork it centres (`SidecarScreen.swift`). Fixed for the same reason as
    /// `artworkSize`.
    fileprivate static let leftColumnWidth: CGFloat = 540

    /// Total top+bottom `padding(80)` stripped from the screen height below to get the finite
    /// height available to the row's content.
    private static let outerPadding: CGFloat = 160
    /// Height reserved so the lyrics stage's height budget still accounts for the progress bar's
    /// footprint, now that the bar sits inside the left column instead of a bottom `safeAreaInset`.
    /// The left column's own content (artwork, title/artist, transport, progress bar) is a `VStack`
    /// and simply grows to whatever height it needs; the right-hand lyrics stage is the one
    /// constrained to `contentHeight`, and reserving this budget keeps its height in the same
    /// right-hand-column ballpark it occupied before the bar moved, rather than growing the lyrics
    /// stage's proposal by the bar's now-freed height.
    private static let progressBarReservedHeight: CGFloat = 72

    private var contentHeight: CGFloat {
        max(0, screenSize.height - Self.outerPadding - Self.progressBarReservedHeight)
    }

    var body: some View {
        // `alignment: .top`, NOT `.center` (`progress/tvos-nowplaying-textcolumn.md`
        // "テキスト列の位置固定" 追記): with `.center`, the title/artist/lyrics column's vertical
        // position was derived from centring it against whichever sibling was taller — normally the
        // fixed-height artwork card, so invisible in the harness's stable states. But the text
        // column's OWN height is NOT fixed (it grows/shrinks with the synced-lyrics block, and
        // during a song switch there is a real in-flight window — `TVNowPlayingView.loadLyrics()` —
        // where `lyricsLines` still holds the PREVIOUS song's lines while `currentSong`/
        // `positionSeconds` have already switched to the new one), so its measured height varies
        // frame to frame. `.center` alignment then re-centres the column every time that height
        // changes, which reads as the text visibly sliding up (or down) rather than staying put —
        // the reported "テキスト部分が全部上に消滅してる" defect. Pinning both children to `.top`
        // makes the title/artist's vertical position depend ONLY on the fixed `padding(80)` origin,
        // never on lyrics content height.
        // Sidecar-style split: a fixed-width LEFT column (artwork, then title/artist BELOW it, then
        // the transport row) and a full-height lyrics stage on the RIGHT when lyrics are present —
        // mirroring `SidecarScreen.artworkAndInfo` + `SidecarScreen.lyricsPane`. Unlike the previous
        // layout, the transport row lives in the left column unconditionally, so lyrics mode no
        // longer replaces it — both hasLyrics states expose the same previous/play-pause/next
        // controls and only the right-hand lyrics stage's presence differs.
        HStack(alignment: .top, spacing: 64) {
            VStack(alignment: .leading, spacing: 20) {
                TVCinematicArtworkCard(artworkId: player.currentSong?.artworkId ?? "", client: client, size: Self.artworkSize)

                VStack(alignment: .leading, spacing: 8) {
                    Text(player.currentSong?.title ?? "")
                        .font(.system(size: 40, weight: .medium))
                        .lineLimit(1)
                    Text(player.currentSong?.artist ?? "")
                        .font(.system(size: 24))
                        .foregroundStyle(TVDesignTokens.textSecondary)
                        .lineLimit(1)
                }

                TVNowPlayingTransportBar(player: player)
                    .opacity(TVAmbientPresentation.chromeOpacity(ambient: ambient))
                    // `.disabled` also removes the buttons from the tvOS focus tree, so a Select
                    // press while the chrome is invisible can't blind-toggle playback.
                    .disabled(ambient)
                    .padding(.top, 8)

                // Lives in the left column, under the transport row, rather than a bottom
                // `safeAreaInset` — the previous placement centred the bar horizontally across the
                // whole screen, which read as sitting under the (right-hand) lyrics pane while every
                // other control stayed left-aligned. Width matches `leftColumnWidth` via
                // `TVNowPlayingProgressBar`'s own frame below, not this VStack's `.leading` alignment
                // alone, since the bar's internal `HStack` needs an explicit width to lay its time
                // labels out against.
                TVNowPlayingProgressBar(player: player)
                    .opacity(TVAmbientPresentation.chromeOpacity(ambient: ambient))
                    .padding(.top, 8)
            }
            .frame(width: Self.leftColumnWidth, alignment: .leading)

            // Explicit `maxHeight: .infinity`, capped by `contentHeight` below, so
            // `TVLyricsStageView`'s `GeometryReader` always receives a finite proposal instead of
            // the unbounded one an unconstrained flexible child would get. `.clipped()` on top of
            // the stage's own edge-fade mask is a hard backstop: no overflowing lyric line can paint
            // outside this column into the left column's area.
            if hasLyrics {
                TVLyricsStageView(player: player, lines: lines)
                    .frame(maxWidth: .infinity, maxHeight: contentHeight, alignment: .leading)
                    .clipped()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: TVAmbientPresentation.transitionDuration), value: hasLyrics)
            }
        }
        // Explicit leading-aligned, full-width frame: without it, an `HStack` with only its first
        // child present (no lyrics — the `if hasLyrics` branch contributes nothing) sizes itself to
        // that child's intrinsic width and gets CENTRED by the enclosing `ZStack`, pulling the whole
        // left column — artwork included — away from the fixed leading position it has when lyrics
        // ARE present. That regressed the very "artwork never moves" guarantee this type exists to
        // provide, just triggered by lyrics *absence* instead of the async load this type's doc
        // comment already covers. Pinning the HStack itself to `.leading` makes the left column's
        // horizontal position constant regardless of whether the lyrics stage is mounted.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(80)
    }
}

private struct TVNowPlayingProgressBar: View {
    let player: MusicPlayerService

    /// Matches `TVNowPlayingStageLayout.leftColumnWidth` — the bar now lives inside that column
    /// (under the transport row) rather than centred across the full screen width.
    private static let width: CGFloat = TVNowPlayingStageLayout.leftColumnWidth

    var body: some View {
        VStack(spacing: 6) {
            TVGradientProgressBar(fraction: player.durationSeconds > 0 ? player.positionSeconds / player.durationSeconds : 0)
                .frame(width: Self.width)
            HStack {
                Text(Self.format(player.positionSeconds))
                Spacer()
                Text(Self.format(player.durationSeconds))
            }
            .font(.caption)
            .foregroundStyle(TVDesignTokens.textSecondary)
            .frame(width: Self.width)
        }
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct TVNowPlayingTransportBar: View {
    let player: MusicPlayerService

    var body: some View {
        HStack(spacing: 56) {
            Button {
                Task { await player.previous() }
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(TVTransportButtonStyle(size: 32))
            .accessibilityLabel(String(localized: "tv.nowPlaying.previous"))
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(TVTransportButtonStyle(size: 44))
            .accessibilityLabel(String(localized: player.isPlaying ? "tv.nowPlaying.pause" : "tv.nowPlaying.play"))
            Button {
                Task { await player.next() }
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(TVTransportButtonStyle(size: 32))
            .accessibilityLabel(String(localized: "tv.nowPlaying.next"))
        }
    }
}

/// Borderless, icon-only focus treatment for the Now Playing transport row (`markdown/appletv-servermode-plan.md`
/// Phase 2 polish). tvOS's default `.card` button style draws a grey capsule behind focused
/// buttons, which reads as a settings-dialog control rather than a 10-foot music surface — this
/// style instead lifts the SF Symbol itself: a gentle scale-up, a brightness/weight jump from
/// secondary to full white, and a soft glow, all animated so focus changes feel smooth rather than
/// snapping. Not `private` — also reused by `TVRelayBannerView`'s transport row
/// (`TVBrowseView.swift`) so the relay banner's play/pause/stop buttons match the same cinematic
/// focus treatment.
struct TVTransportButtonStyle: ButtonStyle {
    let size: CGFloat
    @Environment(\.isFocused) private var isFocused

    /// Layout-shift fix (`progress/tvos-playback.md` "フォーカス時のレイアウトシフト" 追記): the
    /// focus↔unfocus weight lift (`.regular` → `.semibold`) changes the SF Symbol glyph's
    /// *intrinsic* metrics, which used to reflow sibling views (artwork, title/artist labels)
    /// whenever a transport button gained/lost focus. Reserving a fixed frame sized for the
    /// LARGEST focused state (icon at `size`, scaled by the focused `scaleEffect`, plus padding)
    /// makes the button's contribution to its parent's layout constant regardless of focus —
    /// only content *inside* that frame changes (weight, colour, glow), and `scaleEffect` is
    /// render-only so it never affects layout either. `size * 1.22` matches the focused
    /// `scaleEffect` factor below so the visually-largest glyph still fits inside the reserved box.
    private var reservedDimension: CGFloat { (size * 1.22) + 40 } // 40 = 20pt padding × 2

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: isFocused ? .semibold : .regular))
            .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.55))
            .shadow(color: .white.opacity(isFocused ? 0.45 : 0), radius: isFocused ? 18 : 0)
            .frame(width: reservedDimension, height: reservedDimension)
            .scaleEffect((isFocused ? 1.22 : 1.0) * (configuration.isPressed ? 0.92 : 1.0))
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

#if DEBUG
/// Preview-only harness for `UXTV_PREVIEW=nowplaying` (see `UXMusicTVApp`), rendering the
/// lyrics-focus layout with rich stub data — fake title/artist/artwork id, a 3-line lyrics window
/// mid-song, and 38% progress — so the cinematic design can be screenshotted in the simulator
/// without pairing to a host. See `progress/tvos-design.md`.
///
/// Also driven with `lines: []` for `UXTV_PREVIEW=nowplayingnolyrics`, which exercises the
/// no-lyrics/artwork-only layout as a stable, non-async-dependent counterpart to `nowplaying` —
/// needed to visually confirm the artwork/left-column geometry documented as fixed in
/// `TVNowPlayingStageLayout` is IDENTICAL between the two states, not just non-animated.
struct TVNowPlayingPreviewHarness: View {
    private let player = MusicPlayerService()
    private let client = RemoteAPIClient(baseURLString: "http://198.51.100.1:9999")
    private let lines: [TranslatedTimedLine]

    /// Includes a 和訳 pairing and an `[間奏]` marker so the harness screenshots exercise both
    /// bilingual rendering and interlude blanking, not just the plain single-language case.
    private static let defaultLines: [TranslatedTimedLine] = [
        .init(id: 0, startTime: 0, text: "Before the night breaks", translation: "夜が明ける前に"),
        .init(id: 1, startTime: 10, text: "I want to send you this song", translation: "この歌を君に届けたい"),
        .init(id: 2, startTime: 20, text: "[間奏]", translation: nil),
        .init(id: 3, startTime: 30, text: "So you can feel we're connected", translation: "繋がっていると感じられるように"),
        .init(id: 4, startTime: 40, text: "However far apart we are", translation: "遠く離れていても"),
    ]

    init(lines: [TranslatedTimedLine] = Self.defaultLines) {
        self.lines = lines
    }

    var body: some View {
        GeometryReader { screenGeo in
            ZStack {
                TVCinematicBackground()
                TVNowPlayingAmbientBackground(artworkId: "preview", client: client)
                TVNowPlayingStageLayout(player: player, client: client, lines: lines, screenSize: screenGeo.size)
            }
        }
        .background(TVDesignTokens.charcoalBase.ignoresSafeArea())
        .onAppear {
            player.configureForPreview(
                song: Song(id: "preview", path: "", title: "夜明けのメロディー", artist: "UX Music Demo", artworkId: "preview"),
                isPlaying: true,
                positionSeconds: 15.2,
                durationSeconds: 40
            )
        }
    }
}

/// Preview-only harness for `UXTV_PREVIEW=nowplayingambient` — renders the REAL `TVNowPlayingView`
/// (not just one of its layouts) with a preview-configured player and never touches the remote, so
/// leaving it alone for `TVAmbientStateMachine.idleTimeout` seconds reproduces the reported defect's
/// exact conditions: 「操作を止めてから30秒程度経つと背景だけが残り、UIやジャケットが消えてしまう」.
/// Screenshot it immediately and again after ~35s — with the `TVAmbientPresentation` fix both frames
/// still show the artwork and track info; only the transport row and progress bar fade out.
/// `client` points at a TEST-NET address so `loadLyrics()`'s fetch fails fast and the harness settles
/// on the artwork-centric layout (the one whose disappearance was reported) rather than hanging.
struct TVNowPlayingAmbientPreviewHarness: View {
    private let player = MusicPlayerService()
    private let client = RemoteAPIClient(baseURLString: "http://198.51.100.1:9999")

    var body: some View {
        TVNowPlayingView(player: player, client: client)
            .onAppear {
                player.configureForPreview(
                    song: Song(id: "preview", path: "", title: "夜明けのメロディー", artist: "UX Music Demo", artworkId: "preview"),
                    isPlaying: true,
                    positionSeconds: 15.2,
                    durationSeconds: 240
                )
            }
    }
}
#endif
