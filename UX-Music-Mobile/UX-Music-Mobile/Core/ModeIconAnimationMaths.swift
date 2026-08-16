import SwiftUI

/// Pure maths behind the Watch shuffle/repeat icons' "stroke slides along its own path" tap
/// animation — the desktop app's signature motion (see `src/renderer/js/ui/player-ui.ts`,
/// `runShuffleAnimation`/`runLoopAnimation`), reproduced on watchOS with SwiftUI-drawn vector
/// icons (`WatchModeIconViews.swift`) since static SF Symbols/imagesets cannot express it.
///
/// Kept free of any view-tree state (no `@State`, no animation-stage orchestration) so the maths
/// is unit-testable without constructing a live view hierarchy — see
/// `ModeIconAnimationMathsTests.swift`. Shared across the app, Watch, and test targets because the
/// same formulas would apply if this animation were ever reused outside the Watch target.
enum ModeIconAnimationMaths {
    /// Percent-of-path-length positions used by the desktop animation's three stages, reproduced
    /// verbatim from `player-ui.ts`'s `POS_STANDARD` / `POS_EXIT` / `POS_ENTER`.
    static let posStandard: Double = 100
    static let posExit: Double = 130
    static let posEnter: Double = -30

    /// `dashOf(pos, len)` from `player-ui.ts`: the stroke-dashoffset that places a dash segment
    /// exactly `pos`% along a path of length `len`, given a dash pattern of `[len, len * 3]` (one
    /// dash the length of the whole path, followed by a gap three times as long, so at most one
    /// dash segment ever intersects the path). As `pos` increases, the returned value *decreases*
    /// — this matches SwiftUI's `StrokeStyle.dashPhase` with no sign flip, because Core Graphics'
    /// dash phase and SVG's `stroke-dashoffset` share the same underlying convention (both
    /// originate from PostScript's `setdash`: painting at arc-length `s` is "on" when
    /// `(s + offset) mod patternLength` falls inside a dash segment). Verified numerically against
    /// `CGPath.copy(dashingWithPhase:lengths:)` — the same primitive backing both `CGContext` line
    /// dashing and SwiftUI's `StrokeStyle` — rather than assumed: passing `dashOffset(pos:length:)`
    /// straight through as `dashPhase` reproduces the desktop's exact visible/hidden segments at
    /// every stage (full path at `posStandard`, shrinking from the near/start edge while anchored
    /// at the far/end edge at `posExit`, fully hidden at `posEnter`, growing back in from the
    /// start edge as `pos` returns to `posStandard`).
    static func dashOffset(pos: Double, length: Double) -> Double {
        length - (pos / 100) * length
    }

    /// Arrow-head translateX from `player-ui.ts`: `(pos - 100) / 100 * pathLen * scale`. The
    /// arrow-head glyphs are small independent "V" paths (not part of the stroked line itself), so
    /// unlike the line's dash animation — where the slide direction falls out of the path's own
    /// geometry/winding — the head must be translated explicitly, and its direction must be
    /// manually mirrored (`mirrored: true`) for strokes whose slide should visually go the
    /// opposite way, e.g. the repeat icon's bottom arc (see `player-ui.ts`'s `botExitX`/`botEnterX`,
    /// which negate the same formula used for the top arc's head).
    ///
    /// `scale` mirrors the desktop's `renderedSize / 24` (the icon's actual on-screen size versus
    /// its 24×24 SVG viewBox) — callers building the icon geometry in the native 24-unit coordinate
    /// space and relying on an outer `.scaleEffect` for final sizing should pass `scale: 1`, since
    /// the outer scale then applies uniformly to this offset along with everything else.
    static func headOffsetX(pos: Double, pathLength: Double, scale: Double, mirrored: Bool) -> Double {
        let base = (pos - posStandard) / 100 * pathLength * scale
        return mirrored ? -base : base
    }

    /// Approximates a `Path`'s total length by flattening every line/curve element into short
    /// straight segments and summing their Euclidean lengths — the SwiftUI/watchOS equivalent of
    /// the DOM's `SVGGeometryElement.getTotalLength()`, which the desktop animation depends on but
    /// has no watchOS analogue (`Path` exposes no length API). Exact for straight lines; a
    /// polyline-flattening approximation for curves and arcs (arcs are represented as one or more
    /// cubic Bézier segments once the `Path` is converted to a `CGPath`), accurate to a small
    /// fraction of a percent at `sampleCount` ≥ 24 — comfortably enough for the small 24×24-viewBox
    /// icons this is used for.
    static func approximateLength(of path: Path, sampleCount: Int = 64) -> CGFloat {
        var length: CGFloat = 0
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        path.cgPath.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]
                subpathStart = current
            case .addLineToPoint:
                let next = element.points[0]
                length += current.modeIconDistance(to: next)
                current = next
            case .addQuadCurveToPoint:
                let control = element.points[0]
                let end = element.points[1]
                length += Self.flattenedQuadLength(from: current, control: control, to: end, sampleCount: sampleCount)
                current = end
            case .addCurveToPoint:
                let control1 = element.points[0]
                let control2 = element.points[1]
                let end = element.points[2]
                length += Self.flattenedCubicLength(from: current, control1: control1, control2: control2, to: end, sampleCount: sampleCount)
                current = end
            case .closeSubpath:
                length += current.modeIconDistance(to: subpathStart)
                current = subpathStart
            @unknown default:
                break
            }
        }
        return length
    }

    private static func flattenedCubicLength(from p0: CGPoint, control1: CGPoint, control2: CGPoint, to p3: CGPoint, sampleCount: Int) -> CGFloat {
        var length: CGFloat = 0
        var previous = p0
        guard sampleCount > 0 else { return p0.modeIconDistance(to: p3) }
        for i in 1...sampleCount {
            let t = CGFloat(i) / CGFloat(sampleCount)
            let point = cubicBezierPoint(p0: p0, control1: control1, control2: control2, p3: p3, t: t)
            length += previous.modeIconDistance(to: point)
            previous = point
        }
        return length
    }

    private static func flattenedQuadLength(from p0: CGPoint, control: CGPoint, to p2: CGPoint, sampleCount: Int) -> CGFloat {
        var length: CGFloat = 0
        var previous = p0
        guard sampleCount > 0 else { return p0.modeIconDistance(to: p2) }
        for i in 1...sampleCount {
            let t = CGFloat(i) / CGFloat(sampleCount)
            let point = quadBezierPoint(p0: p0, control: control, p2: p2, t: t)
            length += previous.modeIconDistance(to: point)
            previous = point
        }
        return length
    }

    private static func cubicBezierPoint(p0: CGPoint, control1: CGPoint, control2: CGPoint, p3: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * control1.x + 3 * u * t * t * control2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * control1.y + 3 * u * t * t * control2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }

    private static func quadBezierPoint(p0: CGPoint, control: CGPoint, p2: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u * u * p0.x + 2 * u * t * control.x + t * t * p2.x
        let y = u * u * p0.y + 2 * u * t * control.y + t * t * p2.y
        return CGPoint(x: x, y: y)
    }
}

private extension CGPoint {
    func modeIconDistance(to other: CGPoint) -> CGFloat {
        let dx = other.x - x
        let dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }
}
