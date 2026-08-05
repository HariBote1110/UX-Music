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

/// Overload for the bilingual (和訳) line type — same seek behaviour, different associated data.
func nowPlayingLyricsSeekTime(for line: TranslatedTimedLine) -> Double {
    line.startTime
}

/// Mirrors `LRCParser.activeLineIndex(in:at:)` for `TranslatedTimedLine`. Duplicated rather than
/// shared because `LRCParser` lives under `Core/`, which is out of scope for this file to edit —
/// the two must stay in sync by inspection if the "last line at-or-before `time`" rule ever
/// changes.
func nowPlayingActiveTranslatedLineIndex(in lines: [TranslatedTimedLine], at time: Double) -> Int {
    guard !lines.isEmpty else { return 0 }
    var best = 0
    for (i, line) in lines.enumerated() where line.startTime <= time {
        best = i
    }
    return best
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
        // Bilingual (和訳) API: same underlying lyrics file, with a Japanese translation merged
        // in per-line when a translation sidecar was saved. `translation == nil` (interludes, or
        // no translation at all) renders identically to the original single-language view.
        if let mode = model.localBilingualLyricsDisplay(for: song.id) {
            switch mode {
            case .plain(let lines):
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            NowPlayingBilingualPlainLine(line: line)
                        }
                    }
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

/// One line of the plain-text (non-synced) lyrics view, with its 和訳 rendered beneath when
/// present. Kept as its own view (rather than inline in the `ForEach`) so the "no translation ->
/// no extra row, no extra space" rule is a single `if let`, not duplicated per call site.
private struct NowPlayingBilingualPlainLine: View {
    let line: TranslatedPlainLine

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            if let translation = line.translation {
                Text(translation)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

/// Per-line measured height, keyed by line index, collected via a background `GeometryReader`
/// so `nowPlayingLyricsLineOffsets` can lay every line out without SwiftUI's coarse
/// `ScrollViewReader.scrollTo` interpolation getting in the way.
private struct LyricsLineHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Synced (LRC) body

/// Container-offset synced-lyrics view, ported from UX Music Desktop's
/// `applyLyricsMotion`/`.fs-lyrics-inner.fs-lrc` (`src/renderer/js/features/fullscreen-view.ts`,
/// `src/renderer/styles/components.css`): every line is absolutely positioned inside the
/// container, the active line is pinned at a fixed fraction of the container's height, and
/// every other line cascades into place with a per-distance stagger delay. This reproduces
/// Desktop's motion far more faithfully than `ScrollViewReader.scrollTo`, whose interpolation
/// cannot express the wave-like cascade or the fixed on-screen anchor position.
private struct NowPlayingSyncedLyricsScroll: View {
    @Environment(AppModel.self) private var model
    let lines: [TranslatedTimedLine]

    /// Measured height of each line, populated via `LyricsLineHeightKey`. Falls back to a
    /// plausible single-line height until the real measurement lands (first frame only).
    @State private var lineHeights: [Int: CGFloat] = [:]

    /// Accumulated offset (points) from a manual drag, layered on top of the auto-computed
    /// layout. Springs back to zero once auto-scroll resumes.
    @State private var manualDragOffset: CGFloat = 0
    @GestureState private var liveDragTranslation: CGFloat = 0
    @State private var revertTask: Task<Void, Never>?

    /// Wall-clock time the user last dragged the lyrics, used to temporarily suspend
    /// auto-scroll-to-active-line so a manual scroll is not fought by the timeline updates.
    @State private var lastUserScrollAt: Date?

    // Layout parameters ported from Desktop (see `src/renderer/js/features/fullscreen-view.ts`):
    // ANCHOR_RATIO, INTER_BLOCK_GAP, and the active-line `scale(1.091)` from
    // `.fs-lyrics-inner.fs-lrc p.active`.
    private static let anchorRatio: CGFloat = 0.35
    private static let interLineGap: CGFloat = 16
    private static let activeScale: CGFloat = 1.091
    private static let fallbackLineHeight: CGFloat = 44

    // Motion timing. Desktop uses 800ms/40ms-per-line, but that read as sluggish on iPhone's
    // smaller, closer viewport — trimmed to keep the wave-cascade feel while snapping into
    // place noticeably faster. easeOut so the line "arrives" quickly and settles, rather than
    // easing symmetrically in and out.
    private static let motionDuration: Double = 0.3
    private static let delayStep: Double = 0.015
    private static let motionCurve = Animation.easeOut(duration: motionDuration)

    // Off-active-line blur, restored only while auto-scroll is actively tracking playback
    // (i.e. not while the user is mid-drag or within the 3s manual-scroll grace window) —
    // blurring text the user is actively trying to read by hand felt wrong, so it is
    // suppressed for that window and fades back in once auto-scroll resumes.
    private static let blurNeighbourRadius = 6
    private static let blurBase: CGFloat = 0.8
    private static let blurStep: CGFloat = 0.12
    private static let blurMax: CGFloat = 1.5
    private static let blurFade = Animation.easeInOut(duration: 0.25)

    private static let revertSpring = Animation.spring(response: 0.5, dampingFraction: 0.85)

    /// Blur radius for a line at `distance` steps from the active line, capped at `blurMax` and
    /// zero once outside `blurNeighbourRadius` (kept off-screen rows cheap to render).
    private static func blurRadius(distance: Int) -> CGFloat {
        guard distance > 0, distance <= blurNeighbourRadius else { return 0 }
        return min(blurMax, blurBase + blurStep * CGFloat(distance - 1))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { context in
            let position = max(0, model.player.positionSeconds)
            let active = nowPlayingActiveTranslatedLineIndex(in: lines, at: position)
            let secondsSinceUserScroll = lastUserScrollAt.map { context.date.timeIntervalSince($0) }
            let isDragging = liveDragTranslation != 0
            let isAutoScrolling = !isDragging
                && nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll: secondsSinceUserScroll)

            GeometryReader { geo in
                let anchorY = geo.size.height * Self.anchorRatio
                let heights = (0..<lines.count).map { lineHeights[$0] ?? Self.fallbackLineHeight }
                let offsets = nowPlayingLyricsLineOffsets(
                    heights: heights, activeIndex: active, anchorY: anchorY, gap: Self.interLineGap
                )
                let dragOffset = manualDragOffset + liveDragTranslation

                ZStack(alignment: .topLeading) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let isActive = index == active
                        let distance = abs(index - max(0, active))
                        let delay = nowPlayingLyricsLineDelay(index: index, activeIndex: active, stepSeconds: Self.delayStep)
                        let y = (offsets.indices.contains(index) ? offsets[index] : anchorY) + dragOffset
                        let blur = isAutoScrolling ? Self.blurRadius(distance: distance) : 0

                        Button {
                            model.player.seek(to: nowPlayingLyricsSeekTime(for: line))
                        } label: {
                            // The translation (和訳), when present, rides along inside the same
                            // `Button` label as the primary line so the background `GeometryReader`
                            // below (which drives `nowPlayingLyricsLineOffsets`'s cumulative-height
                            // stacking) measures the *combined* row height automatically — no change
                            // to the offset arithmetic itself was needed, only what it measures.
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .lineSpacing(4)
                                    .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.45))
                                    .shadow(color: .white.opacity(isActive ? 0.15 : 0), radius: isActive ? 20 : 0)
                                if let translation = line.translation {
                                    Text(translation)
                                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                                        .foregroundStyle(isActive ? Color.white.opacity(0.6) : Color.white.opacity(0.28))
                                }
                            }
                            .blur(radius: blur)
                            .frame(width: max(0, geo.size.width - 56), alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(isActive ? Self.activeScale : 1, anchor: .leading)
                        .background(
                            GeometryReader { lineGeo in
                                Color.clear.preference(key: LyricsLineHeightKey.self, value: [index: lineGeo.size.height])
                            }
                        )
                        .offset(x: 28, y: y)
                        .animation(Self.motionCurve.delay(delay), value: active)
                        .animation(Self.blurFade, value: isAutoScrolling)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .updating($liveDragTranslation) { value, state, _ in
                            state = value.translation.height
                        }
                        .onChanged { _ in
                            lastUserScrollAt = .now
                            revertTask?.cancel()
                        }
                        .onEnded { value in
                            manualDragOffset += value.translation.height
                            lastUserScrollAt = .now
                            scheduleAutoScrollResume()
                        }
                )
            }
            .onPreferenceChange(LyricsLineHeightKey.self) { lineHeights = $0 }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0.0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.70),
                        .init(color: .black.opacity(0), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    /// Waits for `nowPlayingLyricsShouldAutoScroll`'s resume window (3 seconds of no manual
    /// drag), then springs `manualDragOffset` back to zero so the layout re-anchors on the
    /// active line.
    private func scheduleAutoScrollResume() {
        revertTask?.cancel()
        revertTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard nowPlayingLyricsShouldAutoScroll(
                secondsSinceLastUserScroll: lastUserScrollAt.map { Date().timeIntervalSince($0) }
            ) else { return }
            await MainActor.run {
                withAnimation(Self.revertSpring) { manualDragOffset = 0 }
            }
        }
    }
}
