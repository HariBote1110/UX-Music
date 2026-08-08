import SwiftUI

/// SwiftUI-drawn, animatable replacements for the old `DesktopShuffleIcon`/`DesktopRepeatIcon`
/// static imagesets. The desktop app's signature move on these buttons is that, on tap, the
/// stroke visibly slides along its own path (`runShuffleAnimation`/`runLoopAnimation` in
/// `src/renderer/js/ui/player-ui.ts`) — a static raster/SVG asset cannot express that, so the
/// icons are drawn as `Path`s here instead and animated via `ModeIconAnimator`. The underlying
/// maths (`dashOffset`, `headOffsetX`, path-length approximation) lives in the shared, pure,
/// unit-tested `ModeIconAnimationMaths` (`Core/ModeIconAnimationMaths.swift`).

// MARK: - Geometry

/// Path geometry for both icons, in the same 24×24 viewBox coordinate space as the desktop SVGs
/// (`src/renderer/index.html`, the `#shuffle-btn`/`#loop-btn` markup) so the `d` attributes below
/// translate directly into `Path` construction, and lengths/offsets computed from them line up
/// with the desktop's numbers.
enum ModeIconGeometry {
    static let viewBoxSize: CGFloat = 24

    /// `M2 18 L7 18 C10 18 14 6 17 6 L22 6` — runs left→right, so animating this stroke's dash
    /// toward `posExit`/`posStandard` slides it rightward, matching the desktop.
    static let shuffleTopLine = Path { p in
        p.move(to: CGPoint(x: 2, y: 18))
        p.addLine(to: CGPoint(x: 7, y: 18))
        p.addCurve(to: CGPoint(x: 17, y: 6), control1: CGPoint(x: 10, y: 18), control2: CGPoint(x: 14, y: 6))
        p.addLine(to: CGPoint(x: 22, y: 6))
    }

    /// `M2 6 L7 6 C10 6 14 18 17 18 L22 18` — also runs left→right (mirrored vertically relative
    /// to the top line), so it slides rightward in sync with the top line, just started
    /// `ModeIconAnimator`'s stagger later.
    static let shuffleBottomLine = Path { p in
        p.move(to: CGPoint(x: 2, y: 6))
        p.addLine(to: CGPoint(x: 7, y: 6))
        p.addCurve(to: CGPoint(x: 17, y: 18), control1: CGPoint(x: 10, y: 6), control2: CGPoint(x: 14, y: 18))
        p.addLine(to: CGPoint(x: 22, y: 18))
    }

    /// `M19 3 L22 6 L19 9` — the top line's arrowhead, its midpoint (22, 6) sitting exactly at the
    /// top line's path end.
    static let shuffleHeadTop = Path { p in
        p.move(to: CGPoint(x: 19, y: 3))
        p.addLine(to: CGPoint(x: 22, y: 6))
        p.addLine(to: CGPoint(x: 19, y: 9))
    }

    /// `M19 15 L22 18 L19 21` — the bottom line's arrowhead, midpoint (22, 18) at the bottom
    /// line's path end.
    static let shuffleHeadBottom = Path { p in
        p.move(to: CGPoint(x: 19, y: 15))
        p.addLine(to: CGPoint(x: 22, y: 18))
        p.addLine(to: CGPoint(x: 19, y: 21))
    }

    /// `M3 12 a5 5 0 0 1 5-5 H21` — a quarter circle (centre (8, 12), radius 5) from (3, 12) to
    /// (8, 7), then a straight run to (21, 7). Runs left→right (path start at x=3, end at x=21),
    /// so its dash slides rightward like the shuffle lines.
    static let repeatTopArc = Path { p in
        p.move(to: CGPoint(x: 3, y: 12))
        p.addArc(center: CGPoint(x: 8, y: 12), radius: 5, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.addLine(to: CGPoint(x: 21, y: 7))
    }

    /// `M21 12 a5 5 0 0 1 -5 5 H3` — a quarter circle (centre (16, 12), radius 5) from (21, 12) to
    /// (16, 17), then a straight run to (3, 17). Runs *right→left* (path start at x=21, end at
    /// x=3) — the mirror image of the top arc's direction — so applying the exact same
    /// `dashOffset` formula as the top arc still makes this stroke slide *left*: the mirroring
    /// falls out of the path's own geometry, not out of the maths (see `ModeIconAnimationMaths`'s
    /// doc comment on `dashOffset`). Only the independent arrow-head glyph below needs an
    /// explicit sign flip, since it isn't part of the stroked path itself.
    static let repeatBottomArc = Path { p in
        p.move(to: CGPoint(x: 21, y: 12))
        p.addArc(center: CGPoint(x: 16, y: 12), radius: 5, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: 3, y: 17))
    }

    /// `M18 4 L21 7 L18 10` — the top arc's arrowhead, midpoint (21, 7) at the top arc's path end.
    static let repeatHeadTop = Path { p in
        p.move(to: CGPoint(x: 18, y: 4))
        p.addLine(to: CGPoint(x: 21, y: 7))
        p.addLine(to: CGPoint(x: 18, y: 10))
    }

    /// `M6 14 L3 17 L6 20` — the bottom arc's arrowhead, midpoint (3, 17) at the bottom arc's path
    /// end.
    static let repeatHeadBottom = Path { p in
        p.move(to: CGPoint(x: 6, y: 14))
        p.addLine(to: CGPoint(x: 3, y: 17))
        p.addLine(to: CGPoint(x: 6, y: 20))
    }

    // Lengths computed once (via ModeIconAnimationMaths' numeric flattening — Path exposes no
    // length API) rather than hardcoded, per the two lines/arcs above being geometrically
    // congruent (mirror images of one another), top and bottom lengths coincide in practice, but
    // each is still computed from its own Path for robustness.
    static let shuffleTopLength = ModeIconAnimationMaths.approximateLength(of: shuffleTopLine)
    static let shuffleBottomLength = ModeIconAnimationMaths.approximateLength(of: shuffleBottomLine)
    static let repeatTopLength = ModeIconAnimationMaths.approximateLength(of: repeatTopArc)
    static let repeatBottomLength = ModeIconAnimationMaths.approximateLength(of: repeatBottomArc)
}

// MARK: - Animator

/// Drives the desktop-style three-stage slide sequence for a two-stroke mode icon (shuffle's
/// crossing lines, or repeat's two arcs), reproducing `runShuffleAnimation`/`runLoopAnimation`
/// from `player-ui.ts`:
///   1. both strokes animate `posStandard` → `posExit` over 200ms ease-in (the bottom stroke
///      started `staggerSeconds` after the top);
///   2. an instantaneous, non-animated warp to `posEnter`;
///   3. both animate `posEnter` → `posStandard` over 400ms with timing curve
///      `(0.16, 1, 0.3, 1)`, again staggered the same way.
/// Re-entrant taps while a run is already in flight are ignored, matching the desktop's
/// `shuffleAnimationRunning`/`loopAnimationRunning` guards.
@MainActor
final class ModeIconAnimator: ObservableObject {
    @Published private(set) var topPos: Double = ModeIconAnimationMaths.posStandard
    @Published private(set) var bottomPos: Double = ModeIconAnimationMaths.posStandard

    private let staggerSeconds: Double
    private var isAnimating = false

    /// - Parameter staggerSeconds: delay before the bottom stroke's animation starts, relative to
    ///   the top stroke's. Shuffle uses 120ms (`player-ui.ts`'s `SHUFFLE_STAGGER`); repeat uses 0
    ///   (`runLoopAnimation` starts both arcs together).
    init(staggerSeconds: Double) {
        self.staggerSeconds = staggerSeconds
    }

    func trigger() {
        guard !isAnimating else { return }
        isAnimating = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSequence()
            self.isAnimating = false
        }
    }

    private func runSequence() async {
        let exitDuration = 0.2
        let enterDuration = 0.4
        let exitAnimation = Animation.easeIn(duration: exitDuration)
        let enterAnimation = Animation.timingCurve(0.16, 1, 0.3, 1, duration: enterDuration)

        // Stage 1: exit — top immediately, bottom after the stagger.
        withAnimation(exitAnimation) { topPos = ModeIconAnimationMaths.posExit }
        await sleep(seconds: staggerSeconds)
        withAnimation(exitAnimation) { bottomPos = ModeIconAnimationMaths.posExit }
        await sleep(seconds: exitDuration)

        // Stage 2: instant warp to the enter position — no animation, matching the desktop's
        // non-animated jump between the exit and enter keyframe sets.
        var warp = Transaction()
        warp.disablesAnimations = true
        withTransaction(warp) {
            topPos = ModeIconAnimationMaths.posEnter
            bottomPos = ModeIconAnimationMaths.posEnter
        }

        // Stage 3: enter — top immediately, bottom after the stagger.
        withAnimation(enterAnimation) { topPos = ModeIconAnimationMaths.posStandard }
        await sleep(seconds: staggerSeconds)
        withAnimation(enterAnimation) { bottomPos = ModeIconAnimationMaths.posStandard }
        await sleep(seconds: enterDuration)
    }

    private func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Rendering

/// Renders one two-stroke mode icon (both lines/arcs, both arrow-heads) from an animator's
/// current `topPos`/`bottomPos`. Geometry stays in the native 24-unit coordinate space; a single
/// outer `.scaleEffect` maps it to `iconSize`, which is also why `headOffsetX` below is computed
/// with `scale: 1` — the outer scale applies to that offset along with everything else.
private struct AnimatedTwoStrokeIcon: View {
    let topPath: Path
    let bottomPath: Path
    let topHead: Path
    let bottomHead: Path
    let topLength: CGFloat
    let bottomLength: CGFloat
    let topPos: Double
    let bottomPos: Double
    let mirrorBottomHead: Bool
    let tint: Color
    let iconSize: CGFloat

    var body: some View {
        ZStack {
            topPath
                .stroke(tint, style: strokeStyle(length: topLength, pos: topPos))
            bottomPath
                .stroke(tint, style: strokeStyle(length: bottomLength, pos: bottomPos))
            topHead
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .offset(x: ModeIconAnimationMaths.headOffsetX(pos: topPos, pathLength: topLength, scale: 1, mirrored: false))
            bottomHead
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .offset(x: ModeIconAnimationMaths.headOffsetX(pos: bottomPos, pathLength: bottomLength, scale: 1, mirrored: mirrorBottomHead))
        }
        .frame(width: ModeIconGeometry.viewBoxSize, height: ModeIconGeometry.viewBoxSize)
        .scaleEffect(iconSize / ModeIconGeometry.viewBoxSize)
        .frame(width: iconSize, height: iconSize)
    }

    private func strokeStyle(length: CGFloat, pos: Double) -> StrokeStyle {
        StrokeStyle(
            lineWidth: 2,
            lineCap: .round,
            lineJoin: .round,
            dash: [length, length * 3],
            dashPhase: ModeIconAnimationMaths.dashOffset(pos: pos, length: length)
        )
    }
}

/// Shuffle icon: replaces `Image("DesktopShuffleIcon")`. `iconSize` and `tapFrameSize` default to
/// the original fixed sizing (~20pt icon in a 36pt tap frame), but `WatchNowPlayingView`'s
/// `ViewThatFits` ladder passes smaller values on its more compact rungs so this row can shrink
/// along with the rest of the page. Triggers the slide animation whenever `isActive` changes, i.e.
/// on every tap of the shuffle button (`player.toggleShuffle()` flips `isActive` unconditionally).
struct WatchShuffleIcon: View {
    let isActive: Bool
    var iconSize: CGFloat = 20
    var tapFrameSize: CGFloat = 36

    @StateObject private var animator = ModeIconAnimator(staggerSeconds: 0.12)

    var body: some View {
        AnimatedTwoStrokeIcon(
            topPath: ModeIconGeometry.shuffleTopLine,
            bottomPath: ModeIconGeometry.shuffleBottomLine,
            topHead: ModeIconGeometry.shuffleHeadTop,
            bottomHead: ModeIconGeometry.shuffleHeadBottom,
            topLength: ModeIconGeometry.shuffleTopLength,
            bottomLength: ModeIconGeometry.shuffleBottomLength,
            topPos: animator.topPos,
            bottomPos: animator.bottomPos,
            mirrorBottomHead: false,
            tint: isActive ? .blue : .white.opacity(0.6),
            iconSize: iconSize
        )
        .frame(width: tapFrameSize, height: tapFrameSize)
        .contentShape(Rectangle())
        .onChange(of: isActive) { _, _ in animator.trigger() }
    }
}

/// Repeat icon: replaces `Image("DesktopRepeatIcon")`. Keeps the existing "1" badge overlay for
/// `.one`, tinted like the active state. `iconSize`/`tapFrameSize` default as in `WatchShuffleIcon`
/// — see its doc comment. Triggers the slide animation whenever `repeatMode` changes, i.e. on
/// every tap of the repeat button (`player.cycleRepeatMode()` always advances to a different mode).
struct WatchRepeatIcon: View {
    let repeatMode: WatchRepeatMode
    var iconSize: CGFloat = 20
    var tapFrameSize: CGFloat = 36

    @StateObject private var animator = ModeIconAnimator(staggerSeconds: 0)

    private var tint: Color { repeatMode == .off ? .white.opacity(0.6) : .blue }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AnimatedTwoStrokeIcon(
                topPath: ModeIconGeometry.repeatTopArc,
                bottomPath: ModeIconGeometry.repeatBottomArc,
                topHead: ModeIconGeometry.repeatHeadTop,
                bottomHead: ModeIconGeometry.repeatHeadBottom,
                topLength: ModeIconGeometry.repeatTopLength,
                bottomLength: ModeIconGeometry.repeatBottomLength,
                topPos: animator.topPos,
                bottomPos: animator.bottomPos,
                mirrorBottomHead: true,
                tint: tint,
                iconSize: iconSize
            )

            if repeatMode == .one {
                Text("1")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 11, height: 11)
                    .background(Circle().fill(tint))
            }
        }
        .frame(width: tapFrameSize, height: tapFrameSize)
        .contentShape(Rectangle())
        .onChange(of: repeatMode) { _, _ in animator.trigger() }
    }
}
