import SwiftUI
import UIKit

/// Full-screen Now Playing (`markdown/appletv-servermode-plan.md` Phase 2). Large artwork, track
/// info, progress, and Siri Remote transport controls, plus synced lyrics (falling back to an
/// artwork-centric layout for songs without lyrics) and an ambient presentation after a period of
/// no remote interaction. Media-key handling itself (play/pause/next/previous from the physical
/// remote, Control Centre, etc.) already comes for free from `MusicPlayerService`'s existing
/// `MPRemoteCommandCenter`/`MPNowPlayingInfoCenter` wiring, which is shared unmodified with
/// iOS/watchOS — see `progress/tvos-nowplaying.md` for why no TV-specific seam was needed there.
struct TVNowPlayingView: View {
    let player: MusicPlayerService
    let client: RemoteAPIClient

    @Environment(\.dismiss) private var dismiss
    @State private var lyricsLines: [LRCParser.TimedLine] = []
    @State private var lastInteractionAt = Date()
    @State private var ambientState: TVAmbientStateMachine.State = .normal

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let idleSeconds = context.date.timeIntervalSince(lastInteractionAt)
            let resolved = TVAmbientStateMachine.next(
                current: ambientState,
                isPlaying: player.isPlaying,
                secondsSinceLastInteraction: idleSeconds
            )

            content(ambient: resolved == .ambient)
                .onChange(of: resolved) { _, newValue in ambientState = newValue }
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

    @ViewBuilder
    private func content(ambient: Bool) -> some View {
        ZStack {
            TVCinematicBackground(breathing: ambient)
            TVNowPlayingAmbientBackground(artworkId: player.currentSong?.artworkId ?? "", client: client, ambient: ambient)

            if ambient {
                TVAmbientOverlay(song: player.currentSong, lyricsLines: lyricsLines, player: player)
            } else if lyricsLines.isEmpty {
                TVNowPlayingArtworkLayout(player: player, client: client)
            } else {
                TVNowPlayingLyricsLayout(player: player, client: client, lines: lyricsLines)
            }
        }
        .animation(.easeInOut(duration: 1.2), value: ambient)
    }

    private func registerInteraction() {
        lastInteractionAt = .now
        ambientState = .normal
    }

    /// Menu/Back handler: two-step exit driven by `TVAmbientStateMachine.exitCommand` (pure, unit
    /// tested). While the ambient (screensaver) presentation is up, Menu only wakes the screen back
    /// to normal — it must NOT also dismiss in the same press, or a quick double-press of Menu would
    /// fall through the dismissed `fullScreenCover` straight to the tvOS home screen. Only a Menu
    /// press while already showing the normal layout dismisses back to browse; playback is
    /// untouched either way (see `MusicPlayerService`, which lives above this view).
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
    /// layout exactly as if they had no lyrics at all.
    private func loadLyrics() async {
        guard let song = player.currentSong else {
            lyricsLines = []
            return
        }
        do {
            let payload = try await client.fetchLyrics(songId: song.id)
            guard payload.found, payload.type == "lrc", let raw = payload.content else {
                lyricsLines = []
                return
            }
            lyricsLines = LRCParser.parseTimedLines(raw)
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

private struct TVNowPlayingArtworkLayout: View {
    let player: MusicPlayerService
    let client: RemoteAPIClient

    var body: some View {
        VStack(spacing: 40) {
            TVCinematicArtworkCard(artworkId: player.currentSong?.artworkId ?? "", client: client, size: 560)
            TVNowPlayingInfoBlock(player: player)
            TVNowPlayingTransportBar(player: player)
        }
        .padding(80)
    }
}

private struct TVNowPlayingLyricsLayout: View {
    let player: MusicPlayerService
    let client: RemoteAPIClient
    let lines: [LRCParser.TimedLine]

    var body: some View {
        HStack(alignment: .center, spacing: 64) {
            TVCinematicArtworkCard(artworkId: player.currentSong?.artworkId ?? "", client: client, size: 420)

            VStack(alignment: .leading, spacing: 28) {
                Text(player.currentSong?.title ?? "")
                    .font(.system(size: 40, weight: .medium))
                    .lineLimit(1)
                Text(player.currentSong?.artist ?? "")
                    .font(.system(size: 24))
                    .foregroundStyle(TVDesignTokens.textSecondary)
                    .lineLimit(1)

                TVSyncedLyricsFocusView(lines: lines, positionSeconds: player.positionSeconds)
                    .padding(.top, 12)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(80)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                TVNowPlayingProgressBar(player: player)
                Spacer()
            }
        }
    }
}

/// Three-line "focus" lyrics block: previous line (muted, small), current line (white, larger,
/// with a pink accent bar on the left edge), next line (muted) — smooth vertical transition as
/// lines advance. The active/prev/next indices are all derived from `LRCParser.activeLineIndex`
/// (shared, TDD'd pure function — see `UX-Music-MobileTests/LRCParserTests.swift`); this view only
/// renders that index as a windowed, animated presentation.
struct TVSyncedLyricsFocusView: View {
    let lines: [LRCParser.TimedLine]
    let positionSeconds: Double

    var body: some View {
        let active = LRCParser.activeLineIndex(in: lines, at: positionSeconds)
        VStack(alignment: .leading, spacing: 14) {
            lineView(at: active - 1, style: .muted)
            currentLineView(at: active)
            lineView(at: active + 1, style: .muted)
        }
        .animation(.easeInOut(duration: 0.4), value: active)
    }

    private enum LineStyle { case muted }

    @ViewBuilder
    private func lineView(at index: Int, style: LineStyle) -> some View {
        if lines.indices.contains(index) {
            Text(lines[index].text.isEmpty ? " " : lines[index].text)
                .font(.system(size: 24, design: .rounded))
                .foregroundStyle(TVDesignTokens.textTertiary)
                .lineLimit(1)
                .id(lines[index].id)
        } else {
            Text(" ").font(.system(size: 24)).hidden()
        }
    }

    @ViewBuilder
    private func currentLineView(at index: Int) -> some View {
        if lines.indices.contains(index) {
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(TVDesignTokens.signaturePink)
                    .frame(width: 4, height: 40)
                Text(lines[index].text.isEmpty ? " " : lines[index].text)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .id(lines[index].id)
        }
    }
}

private struct TVNowPlayingInfoBlock: View {
    let player: MusicPlayerService

    var body: some View {
        VStack(spacing: 12) {
            Text(player.currentSong?.title ?? "")
                .font(.system(size: 34, weight: .medium))
                .lineLimit(1)
            Text(player.currentSong?.artist ?? "")
                .font(.system(size: 22))
                .foregroundStyle(TVDesignTokens.textSecondary)
                .lineLimit(1)
            TVNowPlayingProgressBar(player: player)
        }
    }
}

private struct TVNowPlayingProgressBar: View {
    let player: MusicPlayerService

    var body: some View {
        VStack(spacing: 6) {
            TVGradientProgressBar(fraction: player.durationSeconds > 0 ? player.positionSeconds / player.durationSeconds : 0)
                .frame(width: 480)
            HStack {
                Text(Self.format(player.positionSeconds))
                Spacer()
                Text(Self.format(player.durationSeconds))
            }
            .font(.caption)
            .foregroundStyle(TVDesignTokens.textSecondary)
            .frame(width: 480)
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
struct TVNowPlayingPreviewHarness: View {
    private let player = MusicPlayerService()
    private let client = RemoteAPIClient(baseURLString: "http://198.51.100.1:9999")

    private static let lines: [LRCParser.TimedLine] = [
        .init(id: 0, startTime: 0, text: "夜が明ける前に"),
        .init(id: 1, startTime: 10, text: "この歌を君に届けたい"),
        .init(id: 2, startTime: 20, text: "繋がっていると感じられるように"),
        .init(id: 3, startTime: 30, text: "遠く離れていても"),
        .init(id: 4, startTime: 40, text: "この音楽が架け橋になる"),
    ]

    var body: some View {
        ZStack {
            TVCinematicBackground()
            TVNowPlayingAmbientBackground(artworkId: "preview", client: client)
            TVNowPlayingLyricsLayout(player: player, client: client, lines: Self.lines)
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
#endif

/// Ambient (screensaver-style) presentation: same drifting blurred artwork as the base layer, with
/// track info and (if present) the current lyric line overlaid quietly. Any interaction — handled
/// by the parent `TVNowPlayingView`'s `onMoveCommand`/`onTapGesture`/`onExitCommand` — returns to
/// the normal layout.
private struct TVAmbientOverlay: View {
    let song: Song?
    let lyricsLines: [LRCParser.TimedLine]
    let player: MusicPlayerService

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(song?.title ?? "")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Text(song?.artist ?? "")
                .font(.system(size: 18))
                .foregroundStyle(TVDesignTokens.textSecondary)
            if !lyricsLines.isEmpty {
                let active = LRCParser.activeLineIndex(in: lyricsLines, at: player.positionSeconds)
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TVDesignTokens.signaturePink.opacity(0.6))
                        .frame(width: 3, height: 22)
                    Text(lyricsLines[active].text)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(.top, 8)
                .animation(.easeInOut(duration: 0.4), value: active)
            }
        }
        .padding(.bottom, 120)
        .transition(.opacity)
    }
}
