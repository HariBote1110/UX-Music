import SwiftUI

/// How long after the user last touch-scrolled the lyrics list before auto-scroll-to-active-line
/// resumes. `nil` (no user scroll yet) always allows auto-scroll.
func nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll: TimeInterval?) -> Bool {
    guard let secondsSinceLastUserScroll else { return true }
    return secondsSinceLastUserScroll >= 3.0
}

/// The playback position a synced-lyrics line should seek to when tapped.
func nowPlayingLyricsSeekTime(for line: LRCParser.TimedLine) -> Double {
    line.startTime
}

/// Edge-fade coefficient (0…1) for a given vertical fraction (0 = top, 1 = bottom) of the
/// synced-lyrics container. Mirrors UX Music Desktop's `.fs-lyrics-container` mask-image
/// (`linear-gradient(to bottom, transparent 0%, black 8%, black 70%, transparent 100%)`):
/// fades in across the top 8% and out across the bottom 30%, full opacity in between.
/// Out-of-range fractions clamp to 0 (fully faded).
func nowPlayingLyricsFadeOpacity(fraction: CGFloat) -> CGFloat {
    guard fraction >= 0, fraction <= 1 else { return 0 }
    let topBand: CGFloat = 0.08
    let bottomBandStart: CGFloat = 0.70
    if fraction < topBand {
        return fraction / topBand
    }
    if fraction > bottomBandStart {
        return max(0, 1 - (fraction - bottomBandStart) / (1 - bottomBandStart))
    }
    return 1
}

/// Vertical offset (from the container's top edge) for every synced-lyrics line, given each
/// line's measured height. Mirrors Desktop's `applyLyricsMotion` in
/// `src/renderer/js/features/fullscreen-view.ts`: the active line (or index 0 if none is
/// active yet) is pinned at `anchorY`, and every other line is stacked above/below it by
/// cumulative height + a fixed inter-line `gap`.
func nowPlayingLyricsLineOffsets(heights: [CGFloat], activeIndex: Int, anchorY: CGFloat, gap: CGFloat) -> [CGFloat] {
    let n = heights.count
    guard n > 0 else { return [] }

    let base = min(max(0, activeIndex), n - 1)
    var offsets = [CGFloat](repeating: 0, count: n)
    offsets[base] = anchorY

    if base + 1 < n {
        for i in (base + 1)..<n {
            offsets[i] = offsets[i - 1] + heights[i - 1] + gap
        }
    }
    if base > 0 {
        for i in stride(from: base - 1, through: 0, by: -1) {
            offsets[i] = offsets[i + 1] - heights[i] - gap
        }
    }
    return offsets
}

/// Stagger delay (seconds) for a line's transition, proportional to its distance from the
/// active line — mirrors Desktop's `MOTION_DELAY_STEP_MS` cascade (`dist * 40ms`).
func nowPlayingLyricsLineDelay(index: Int, activeIndex: Int, stepSeconds: Double) -> Double {
    let effectiveActive = activeIndex >= 0 ? activeIndex : 0
    return Double(abs(index - effectiveActive)) * stepSeconds
}

/// Full-screen lyrics viewer (plain `.txt` or synced `.lrc` using `MusicPlayerService.positionSeconds`).
/// Shares the same ambient-glow background as `NowPlayingView` for a consistent Apple-Music-like feel.
struct NowPlayingLyricsScreen: View {
    @Environment(AppModel.self) private var model
    let song: Song
    /// Palette handed down from `NowPlayingView` so the background glow matches the player screen
    /// without waiting for a fresh artwork-colour extraction.
    let palette: ArtworkPlaybackPalette?
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NowPlayingAmbientBackground(palette: palette)
                .ignoresSafeArea(.all)

            // Darken the ambient glow so lyric text keeps sufficient contrast.
            Color.black.opacity(0.35)
                .ignoresSafeArea(.all)

            lyricsBody

            NowPlayingNavIconButton(action: { isPresented = false }, accessibilityLabel: "閉じる") {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.player.currentSong?.id) { _, newId in
            if newId != song.id {
                isPresented = false
            }
        }
    }

    @ViewBuilder
    private var lyricsBody: some View {
        if let mode = model.localLyricsDisplay(for: song.id) {
            switch mode {
            case .plain(let text):
                ScrollView {
                    Text(text)
                        .font(.system(size: 20, weight: .regular, design: .rounded))
                        .lineSpacing(10)
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                }
            case .synced(let lines):
                NowPlayingSyncedLyricsScroll(lines: lines)
            }
        } else {
            ContentUnavailableView {
                Label("歌詞がありません", systemImage: "text.page")
            } description: {
                Text("この曲は保存された歌詞ファイルがありません。リモートライブラリからダウンロードした曲は、デスクトップ側に歌詞がある場合に自動で取り込まれます。")
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding()
        }
    }
}

// MARK: - Synced (LRC) body

private struct NowPlayingSyncedLyricsScroll: View {
    @Environment(AppModel.self) private var model
    let lines: [LRCParser.TimedLine]

    /// Wall-clock time the user last dragged the scroll view, used to temporarily suspend
    /// auto-scroll-to-active-line so a manual scroll is not fought by the timeline updates.
    @State private var lastUserScrollAt: Date?

    /// Apple-Music-style "line lifts into place" spring, shared by the scroll-to-active-line
    /// animation and every row's scale/opacity/blur transition so they move in lockstep instead
    /// of the scroll settling before (or after) the text finishes fading in.
    private static let autoScrollSpring = Animation.spring(response: 0.6, dampingFraction: 0.8)

    /// How many lines either side of the active line still receive the blur treatment. Blurring
    /// every off-screen row is wasted GPU work (LazyVStack keeps them alive once measured), so
    /// only rows close enough to ever be visible pay for it.
    private static let blurNeighbourRadius = 6

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { context in
            let position = max(0, model.player.positionSeconds)
            let active = LRCParser.activeLineIndex(in: lines, at: position)
            let secondsSinceUserScroll = lastUserScrollAt.map { context.date.timeIntervalSince($0) }

            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            Spacer(minLength: geo.size.height * 0.35)

                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                let isActive = index == active
                                let isNearActive = active >= 0 && abs(index - active) <= Self.blurNeighbourRadius
                                Button {
                                    model.player.seek(to: nowPlayingLyricsSeekTime(for: line))
                                } label: {
                                    Text(line.text.isEmpty ? " " : line.text)
                                        .font(.system(size: 26, weight: isActive ? .bold : .semibold, design: .rounded))
                                        .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.35))
                                        .blur(radius: isActive ? 0 : (isNearActive ? 2.2 : 0))
                                        .scaleEffect(isActive ? 1.05 : 1, anchor: .leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(line.id)
                                }
                                .buttonStyle(.plain)
                                .animation(Self.autoScrollSpring, value: isActive)
                            }

                            Spacer(minLength: geo.size.height * 0.35)
                        }
                        .padding(.horizontal, 28)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4).onChanged { _ in
                            lastUserScrollAt = .now
                        }
                    )
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black.opacity(0), location: 0.0),
                                .init(color: .black, location: 0.12),
                                .init(color: .black, location: 0.82),
                                .init(color: .black.opacity(0), location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .onAppear {
                        guard active >= 0, active < lines.count else { return }
                        proxy.scrollTo(lines[active].id, anchor: .center)
                    }
                    .onChange(of: active) { _, newIndex in
                        guard newIndex >= 0, newIndex < lines.count else { return }
                        guard nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll: secondsSinceUserScroll) else { return }
                        let target = lines[newIndex].id
                        withAnimation(Self.autoScrollSpring) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}
