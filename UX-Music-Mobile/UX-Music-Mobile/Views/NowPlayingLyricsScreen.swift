import SwiftUI

/// How long after the user last touch-scrolled the lyrics list before auto-scroll-to-active-line
/// resumes. `nil` (no user scroll yet) always allows auto-scroll.
func nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll: TimeInterval?) -> Bool {
    guard let secondsSinceLastUserScroll else { return true }
    return secondsSinceLastUserScroll >= 3.0
}

/// The playback position a synced-lyrics line should seek to when tapped. Generic over
/// `LyricsTimedLine` so it covers both the plain `LRCParser.TimedLine` and the bilingual (和訳)
/// `TranslatedTimedLine` with one implementation.
func nowPlayingLyricsSeekTime<Line: LyricsTimedLine>(for line: Line) -> Double {
    line.startTime
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

            NowPlayingNavIconButton(action: { isPresented = false }, accessibilityLabel: String(localized: "Close")) {
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
                Label("No Lyrics", systemImage: "text.page")
            } description: {
                Text("This song has no saved lyrics file. Songs downloaded from the remote library are imported automatically when the desktop has lyrics available.")
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
/// so `SidecarLyricsLayout.tops` can lay every line out without SwiftUI's coarse
/// `ScrollViewReader.scrollTo` interpolation getting in the way.
private struct LyricsLineHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Synced (LRC) body

/// Container-offset synced-lyrics view, converged onto the shared `Core/LyricsStageKit.swift`
/// Desktop-parity primitives (`SidecarLyricsLayout.tops`, `SidecarLyricsMotionPolicy`,
/// `SidecarLyricsEdgeFade`, `SidecarActiveLineUpdatePolicy`) so its motion matches UX Music
/// Desktop's fullscreen synced-lyrics pane and the iPad Sidecar screen: every line is
/// absolutely positioned inside the container, the active line is pinned at 35% of the
/// container's height, and every other line cascades into place over 0.8s with a per-distance
/// stagger delay on CSS's default `ease` timing curve. See
/// `progress/iphone-lyrics-desktop-parity.md`.
///
/// The one intentional divergence from Desktop/Sidecar is mobile-only: a manual drag-to-peek
/// gesture with a 3s auto-resume window (`manualDragOffset`/`liveDragTranslation`/
/// `nowPlayingLyricsShouldAutoScroll`), layered additively on top of the shared layout's
/// `y` offsets.
private struct NowPlayingSyncedLyricsScroll: View {
    @Environment(AppModel.self) private var model
    let lines: [TranslatedTimedLine]

    /// `-1` means "nothing active yet" (before the first line's timestamp — see
    /// `SidecarLyricsMotionPolicy.activeIndex`), matching Desktop's initial state. Updated at
    /// most once per genuine active-line change (`SidecarActiveLineUpdatePolicy`) rather than on
    /// every tick, so the lyric `ForEach` only re-diffs when the highlighted line moves.
    @State private var activeIndex = -1
    /// Stable anchor for the periodic tick below — a `.now` re-evaluated on every body
    /// reconstruction has no settled cadence when the tick writes `@State` this view reads
    /// (`activeIndex`). See `SidecarScreen.progressScheduleAnchor`'s doc comment.
    @State private var lyricsScheduleAnchor = Date()

    /// Measured height of each line, populated via `LyricsLineHeightKey`. Falls back to a
    /// plausible single-line height until the real measurement lands (first frame only).
    @State private var lineHeights: [Int: CGFloat] = [:]

    /// Accumulated offset (points) from a manual drag, layered on top of the auto-computed
    /// layout. Springs back to zero once auto-scroll resumes. Mobile-only — Desktop/Sidecar
    /// have no drag-to-peek.
    @State private var manualDragOffset: CGFloat = 0
    @GestureState private var liveDragTranslation: CGFloat = 0
    @State private var revertTask: Task<Void, Never>?

    /// Wall-clock time the user last dragged the lyrics, used to temporarily suspend
    /// auto-scroll-to-active-line so a manual scroll is not fought by the timeline updates.
    @State private var lastUserScrollAt: Date?

    /// Placeholder height for any line not yet measured, so far-off lines can still be slotted
    /// into the cumulative layout before they have ever rendered.
    private static let fallbackLineHeight: CGFloat = 44
    /// Horizontal inset for the lyrics column, matching the plain-text branch's `.padding(28)`.
    private static let horizontalInset: CGFloat = 28
    private static let revertSpring = Animation.spring(response: 0.5, dampingFraction: 0.85)

    // Mirrors SidecarLyricsTranslationStyle (private to SidecarScreen.swift): the 和訳
    // (translation) subline is `0.7em` of the 28pt primary, a flat `rgba(255,255,255,0.5)` that
    // does not swap with active state, and a 4pt gap below the primary line.
    private static let translationFontSize: CGFloat = 20
    private static let translationOpacity: Double = 0.5
    private static let translationBlockGap: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let paneHeight = geo.size.height
            let paneWidth = geo.size.width
            let heights = (0..<lines.count).map { lineHeights[$0] ?? Self.fallbackLineHeight }
            let baseIndex = lines.isEmpty ? 0 : min(max(0, activeIndex), lines.count - 1)
            let tops = SidecarLyricsLayout.tops(heights: heights, baseIndex: baseIndex, paneHeight: paneHeight)
            let dragOffset = manualDragOffset + liveDragTranslation

            ZStack(alignment: .topLeading) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    let isActive = index == activeIndex
                    let distance = abs(index - baseIndex)
                    // `y` is the shared layout offset only; the mobile drag offset is added
                    // *outside* the `value:` so a drag stays instant (no timing-curve lag)
                    // while a genuine active-line change still animates the cascade.
                    let y = index < tops.count ? tops[index] : 0

                    Button {
                        model.player.seek(to: nowPlayingLyricsSeekTime(for: line))
                    } label: {
                        // The 和訳, when present, rides along inside the same block so the
                        // background `GeometryReader` measures the combined row height and
                        // `SidecarLyricsLayout.tops`'s cumulative stacking absorbs it.
                        VStack(alignment: .leading, spacing: Self.translationBlockGap) {
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(isActive ? 1 : 0.45))
                                .shadow(color: .white.opacity(isActive ? 0.15 : 0), radius: isActive ? 24 : 0)
                            if let translation = line.translation {
                                Text(translation)
                                    .font(.system(size: Self.translationFontSize, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(Self.translationOpacity))
                            }
                        }
                        .frame(width: paneWidth / SidecarLyricsMotionPolicy.activeLineScale, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(isActive ? SidecarLyricsMotionPolicy.activeLineScale : 1, anchor: .leading)
                    .background(
                        GeometryReader { lineGeo in
                            Color.clear.preference(key: LyricsLineHeightKey.self, value: [index: lineGeo.size.height])
                        }
                    )
                    .offset(y: y + dragOffset)
                    .animation(
                        .timingCurve(0.25, 0.1, 0.25, 1.0, duration: SidecarLyricsMotionPolicy.duration)
                            .delay(SidecarLyricsMotionPolicy.staggerDelay(forDistance: distance)),
                        value: y
                    )
                }
            }
            .frame(width: paneWidth, height: paneHeight, alignment: .topLeading)
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
            .onPreferenceChange(LyricsLineHeightKey.self) { lineHeights = $0 }
        }
        .padding(.horizontal, Self.horizontalInset)
        .mask(SidecarLyricsEdgeFade.gradient)
        .background(
            // Gated tick: recompute the active line a few times a second, but only write
            // `@State` (forcing the `ForEach` to re-diff) on a genuine active-line change.
            // Position source is the LOCAL player — not the sidecar remote fields.
            TimelineView(.periodic(from: lyricsScheduleAnchor, by: 0.2)) { context in
                Color.clear
                    .task(id: context.date) {
                        let position = max(0, model.player.positionSeconds)
                        let newActive = SidecarLyricsMotionPolicy.activeIndex(in: lines, at: position)
                        if SidecarActiveLineUpdatePolicy.shouldUpdate(currentIndex: activeIndex, newIndex: newActive) {
                            activeIndex = newActive
                        }
                    }
            }
        )
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
