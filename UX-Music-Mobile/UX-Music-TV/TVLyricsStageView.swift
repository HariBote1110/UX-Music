import SwiftUI

/// 10-foot typography and spacing for `TVLyricsStageView`. The Sidecar pane's 28pt/20pt pairing is
/// sized for a tablet held at arm's length; a TV is read from a sofa, so the same design is scaled
/// up and given a wider inter-line gap. Kept as named constants (rather than literals in the view)
/// so the "TV type is bigger than Sidecar type, translation is smaller than its primary" contract is
/// unit-testable — see `TVLyricsStageTests`.
enum TVLyricsStageMetrics {
    /// Primary lyric line (Sidecar: `28`).
    static let primaryFontSize: CGFloat = 40
    /// 和訳 subline, Desktop's `.fs-line-translation` `0.7em` of the primary (`components.css:2187`).
    static let translationFontSize: CGFloat = 28
    /// Gap between a primary line and its 和訳 inside one block (Desktop `.fs-line-bilingual`'s
    /// `gap: 4px`, scaled for TV type).
    static let translationGap: CGFloat = 8
    /// Gap between consecutive line blocks (Desktop/Sidecar: `SidecarLyricsLayout.interBlockGap`
    /// = 16). Widened for TV so 40pt lines don't crowd.
    static let interBlockGap: CGFloat = 28
    /// Placeholder height for a line that has never been rendered (and so never measured), used by
    /// the cumulative layout sum until a real measurement arrives.
    static let fallbackLineHeight: CGFloat = 64
    /// Lines whose computed `y` falls further than this outside the pane bounds are not rendered at
    /// all, bounding live views/animations to roughly what's visible plus a margin.
    static let renderMargin: CGFloat = 500
    /// How often the active line is re-derived from the player's position.
    static let tickInterval: TimeInterval = 0.2
    /// Inactive line colour — Desktop's `rgba(255,255,255,0.45)` (`components.css:2143-2162`), a
    /// flat two-state swap with no distance-based falloff.
    static let inactiveOpacity: Double = 0.45
}

/// The tvOS lyrics pane, rendering lyric lines exactly like Desktop's fullscreen LRC pane and the
/// iPad Sidecar screen: **each line moves independently**, absolutely positioned by its own animated
/// `y` offset, rather than the whole list scrolling as one unit. The active line is anchored at
/// `paneHeight * SidecarLyricsLayout.anchorRatio` (35%); every other line stacks above/below it via a
/// running sum of `height + interBlockGap`, and each line's transform animates over
/// `SidecarLyricsMotionPolicy.duration` with a `distance * staggerStep` start delay.
///
/// Replaces the previous `TVSyncedLyricsFocusView`, a fixed three-line window (previous/current/next)
/// with a pink accent bar. That window could only ever show one line of context either side, showed
/// interlude markers such as `[間奏]` verbatim, and had no 和訳 support — all three of which the
/// Sidecar screen had already solved against the Desktop reference
/// (`progress/sidecar-lyrics-fade-and-bilingual.md`). The shared rules now live in
/// `Core/LyricsStageKit.swift` and are used by both screens; only typography differs (see
/// `TVLyricsStageMetrics`).
struct TVLyricsStageView: View {
    let player: MusicPlayerService
    let lines: [TranslatedTimedLine]

    /// `-1` means "nothing active yet" (an instrumental intro before the first timestamp), matching
    /// Desktop's `applyLyricsMotion(-1, true)` initial state. Written at most once per genuine line
    /// change (`SidecarActiveLineUpdatePolicy`) rather than on every tick, so the `ForEach` re-diffs
    /// only when the highlight actually moves.
    @State private var activeIndex = -1
    /// Stable anchor for the `TimelineView` below. MUST NOT be `.now` re-evaluated inside the body:
    /// the tick writes `@State` this view reads, so a schedule re-anchored on every reconstruction
    /// has no settled cadence and can feed back on itself — see `SidecarScreen.progressScheduleAnchor`
    /// and `progress/sidecar-poll-tick-cpu-leak.md`.
    @State private var scheduleAnchor = Date()
    /// Per-line measured heights (index → height) for the cumulative layout sum, mirroring Desktop's
    /// `cachedLrcHeights`.
    @State private var lineHeights: [Int: CGFloat] = [:]

    var body: some View {
        GeometryReader { paneGeo in
            let paneHeight = paneGeo.size.height
            let heights = (0..<lines.count).map { lineHeights[$0] ?? TVLyricsStageMetrics.fallbackLineHeight }
            let baseIndex = lines.isEmpty ? 0 : min(max(0, activeIndex), lines.count - 1)
            let tops = SidecarLyricsLayout.tops(
                heights: heights,
                baseIndex: baseIndex,
                paneHeight: paneHeight,
                interBlockGap: TVLyricsStageMetrics.interBlockGap
            )

            ZStack(alignment: .topLeading) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    let y = index < tops.count ? tops[index] : 0
                    if y > -TVLyricsStageMetrics.renderMargin && y < paneHeight + TVLyricsStageMetrics.renderMargin {
                        lineBlock(line: line, isActive: index == activeIndex, distance: abs(index - baseIndex), index: index, y: y, paneWidth: paneGeo.size.width)
                    }
                }
            }
            .onPreferenceChange(TVLyricsLineHeightKey.self) { newHeights in
                lineHeights.merge(newHeights) { _, new in new }
            }
        }
        .mask(SidecarLyricsEdgeFade.gradient)
        .background(activeLineTicker)
        // A song switch replaces `lines` wholesale (new indices, new heights). Without this reset,
        // `lineHeights` kept the PREVIOUS song's measured heights keyed by index for one or more
        // frames until the new lines re-measured themselves, feeding stale heights into
        // `SidecarLyricsLayout.tops`'s cumulative sum and briefly misplacing every line.
        .onChange(of: lines) { _, _ in
            lineHeights = [:]
        }
    }

    /// One lyric line and (when the desktop has a 和訳 saved) its translation, stacked inside a single
    /// block so both ride the same offset/delay — no separate animation entity — and so the height
    /// preference measures the combined block, letting `SidecarLyricsLayout.tops` absorb the extra
    /// height with no change to its arithmetic. Ported from Desktop's `.fs-line-bilingual`
    /// (`components.css:2182-2190`), whose translation colour is a fixed `rgba(255,255,255,0.5)` that
    /// deliberately does *not* swap with active state.
    @ViewBuilder
    private func lineBlock(line: TranslatedTimedLine, isActive: Bool, distance: Int, index: Int, y: CGFloat, paneWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: TVLyricsStageMetrics.translationGap) {
            Text(SidecarLyricsDisplay.text(for: line.text))
                .font(.system(size: TVLyricsStageMetrics.primaryFontSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(isActive ? 1 : TVLyricsStageMetrics.inactiveOpacity))
                .shadow(color: .white.opacity(isActive ? 0.15 : 0), radius: isActive ? 24 : 0)
            if let translation = line.translation {
                Text(translation)
                    .font(.system(size: TVLyricsStageMetrics.translationFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        // Divided by the active scale so an active line's `scaleEffect` can't push it past the
        // pane's trailing edge — same trick as `SidecarSyncedLyricsList`.
        .frame(width: paneWidth / SidecarLyricsMotionPolicy.activeLineScale, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(isActive ? SidecarLyricsMotionPolicy.activeLineScale : 1, anchor: .leading)
        .offset(y: y)
        .animation(
            .timingCurve(0.25, 0.1, 0.25, 1.0, duration: SidecarLyricsMotionPolicy.duration)
                .delay(SidecarLyricsMotionPolicy.staggerDelay(forDistance: distance)),
            value: y
        )
        .background(
            GeometryReader { lineGeo in
                Color.clear.preference(key: TVLyricsLineHeightKey.self, value: [index: lineGeo.size.height])
            }
        )
    }

    /// Re-derives the active line from the player's position a few times a second. `MusicPlayerService`
    /// publishes `positionSeconds` on its own cadence, which is coarser than a lyric cue needs, so the
    /// stage samples on its own schedule and only commits a genuine line change to `@State`.
    private var activeLineTicker: some View {
        TimelineView(.periodic(from: scheduleAnchor, by: TVLyricsStageMetrics.tickInterval)) { context in
            Color.clear
                .task(id: context.date) {
                    let newActive = SidecarLyricsMotionPolicy.activeIndex(in: lines, at: player.positionSeconds)
                    if SidecarActiveLineUpdatePolicy.shouldUpdate(currentIndex: activeIndex, newIndex: newActive) {
                        activeIndex = newActive
                    }
                }
        }
    }
}

private struct TVLyricsLineHeightKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
