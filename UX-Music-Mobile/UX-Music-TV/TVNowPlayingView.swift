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
        .onExitCommand { registerInteraction() }
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private func content(ambient: Bool) -> some View {
        ZStack {
            TVNowPlayingAmbientBackground(artworkId: player.currentSong?.artworkId ?? "", client: client)

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

/// Blurred, slowly drifting artwork backdrop shared by every Now Playing layout (normal, lyrics,
/// and ambient) so switching between them never has a jarring background swap.
private struct TVNowPlayingAmbientBackground: View {
    let artworkId: String
    let client: RemoteAPIClient
    @State private var driftUp = false

    var body: some View {
        TVArtworkImage(artworkId: artworkId, client: client)
            .scaleEffect(driftUp ? 1.12 : 1.0)
            .blur(radius: 60)
            .overlay(Color.black.opacity(0.55))
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                    driftUp = true
                }
            }
    }
}

private struct TVNowPlayingArtworkLayout: View {
    let player: MusicPlayerService
    let client: RemoteAPIClient

    var body: some View {
        VStack(spacing: 40) {
            TVArtworkImage(artworkId: player.currentSong?.artworkId ?? "", client: client)
                .frame(width: 560, height: 560)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(radius: 40)
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
        HStack(spacing: 64) {
            VStack(spacing: 32) {
                TVArtworkImage(artworkId: player.currentSong?.artworkId ?? "", client: client)
                    .frame(width: 340, height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(radius: 30)
                TVNowPlayingInfoBlock(player: player)
                TVNowPlayingTransportBar(player: player)
            }
            .frame(width: 480)

            TVSyncedLyricsView(lines: lines, positionSeconds: player.positionSeconds)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(80)
    }
}

/// Large-type, current-line-highlighted synced lyrics list for 10-foot viewing. The active line
/// is computed purely by `LRCParser.activeLineIndex` (shared, TDD'd unit — see
/// `UX-Music-MobileTests/LRCParserTests.swift`); this view only turns that index into a smoothly
/// scrolled, highlighted presentation.
struct TVSyncedLyricsView: View {
    let lines: [LRCParser.TimedLine]
    let positionSeconds: Double

    var body: some View {
        let active = LRCParser.activeLineIndex(in: lines, at: positionSeconds)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: line.id == lines[active].id ? 44 : 32, weight: line.id == lines[active].id ? .bold : .regular, design: .rounded))
                            .foregroundStyle(line.id == lines[active].id ? Color.white : Color.white.opacity(0.4))
                            .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: active) { _, _ in
                guard lines.indices.contains(active) else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(lines[active].id, anchor: .center)
                }
            }
        }
    }
}

private struct TVNowPlayingInfoBlock: View {
    let player: MusicPlayerService

    var body: some View {
        VStack(spacing: 12) {
            Text(player.currentSong?.title ?? "")
                .font(.system(size: 34, weight: .bold))
                .lineLimit(1)
            Text(player.currentSong?.artist ?? "")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TVNowPlayingProgressBar(player: player)
        }
    }
}

private struct TVNowPlayingProgressBar: View {
    let player: MusicPlayerService

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: player.durationSeconds > 0 ? player.positionSeconds / player.durationSeconds : 0)
                .frame(width: 480)
            HStack {
                Text(Self.format(player.positionSeconds))
                Spacer()
                Text(Self.format(player.durationSeconds))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
        HStack(spacing: 48) {
            Button {
                Task { await player.previous() }
            } label: {
                Image(systemName: "backward.fill").font(.system(size: 32))
            }
            .accessibilityLabel(String(localized: "tv.nowPlaying.previous"))
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 40))
            }
            .accessibilityLabel(String(localized: player.isPlaying ? "tv.nowPlaying.pause" : "tv.nowPlaying.play"))
            Button {
                Task { await player.next() }
            } label: {
                Image(systemName: "forward.fill").font(.system(size: 32))
            }
            .accessibilityLabel(String(localized: "tv.nowPlaying.next"))
        }
        .buttonStyle(.card)
    }
}

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
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text(song?.artist ?? "")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.55))
            if !lyricsLines.isEmpty {
                let active = LRCParser.activeLineIndex(in: lyricsLines, at: player.positionSeconds)
                Text(lyricsLines[active].text)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 8)
                    .animation(.easeInOut(duration: 0.4), value: active)
            }
        }
        .padding(.bottom, 120)
        .transition(.opacity)
    }
}
