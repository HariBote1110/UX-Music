import Foundation
import SwiftUI

/// Shared "lyrics stage" primitives: the pure (view-free) rules and the one gradient that Desktop's
/// fullscreen lyrics pane, iPad の Sidecar 画面, and the tvOS Now Playing screen all render from.
///
/// These types were first written for `SidecarScreen` (hence the `Sidecar…` names, kept as-is so
/// the existing call sites and their tests stay untouched) but none of them depend on the sidecar
/// screen — they are 1:1 ports of Desktop's `fullscreen-view.ts` / `components.css` behaviour. They
/// live here, in `Core/`, because the tvOS target now shares the same lyrics presentation
/// (`TVLyricsStageView`); duplicating the motion/layout arithmetic per platform would have meant two
/// implementations of the same Desktop parity contract. See `progress/tvos-lyrics-stage.md`.
///
/// File membership: `UX-Music-Mobile` and `UX-Music-TV` targets (Foundation + SwiftUI only, no
/// UIKit — `UIInterfaceOrientationMask` and friends stay behind in `Services/SidecarDirective.swift`,
/// which is iOS-only).

/// Ports Desktop's `fsDisplayText` (`fullscreen-view.ts:13-16`): interludes — blank lines or a
/// literal marker such as `[間奏]` — never show their raw text, only reserved line-height (a single
/// space). Rendering must go through this helper rather than a bare `.isEmpty` check, since a saved
/// LRC's interlude line often carries the literal marker text, not an empty string.
enum SidecarLyricsDisplay {
    static func text(for raw: String) -> String {
        LyricsTranslationMerger.isInterludeText(raw) ? " " : raw
    }
}

/// Chooses which `LyricsTranslationMerger` pairing to apply to a `/v1/remote/lyrics` response's
/// `translationContent`, mirroring `AppModel.localBilingualLyricsDisplay(for:)`'s file-based
/// decision (`.ja.lrc` → timestamp-paired, `.ja.txt` → positional) but driven by the payload's own
/// `translationFormat` string instead of which sidecar file exists on disk — the screens using this
/// (Sidecar, tvOS Now Playing) fetch lyrics directly from the remote endpoint rather than through
/// `LyricsFileStore`.
enum SidecarLyricsTranslationMerge {
    /// - Parameters:
    ///   - primary: The already-parsed timed primary lines.
    ///   - translationContent: Raw `translationContent` from `RemoteLyricsPayload`, or `nil`/blank
    ///     if the desktop has no 和訳 saved for this track.
    ///   - translationFormat: `"lrc"` or `"txt"` (`RemoteLyricsPayload.translationFormat`); any
    ///     other value (including `nil`) is treated as positional `"txt"` pairing, matching
    ///     `LyricsTranslationMerger.mergeTimedWithJaTxt`'s existing "no sidecar file" fallback shape.
    static func merge(
        primary: [LRCParser.TimedLine],
        translationContent: String?,
        translationFormat: String?
    ) -> [TranslatedTimedLine] {
        guard let translationContent = translationContent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !translationContent.isEmpty
        else {
            return primary.map { TranslatedTimedLine(id: $0.id, startTime: $0.startTime, text: $0.text, translation: nil) }
        }
        if translationFormat == "lrc" {
            let translationTimed = LRCParser.parseTimedLines(translationContent)
            return LyricsTranslationMerger.mergeTimedWithJaLRC(primary: primary, translation: translationTimed)
        }
        return LyricsTranslationMerger.mergeTimedWithJaTxt(primary: primary, translationText: translationContent)
    }
}

/// Ported from Desktop's fullscreen lyrics motion (`src/renderer/js/features/fullscreen-view.ts`'s
/// `applyLyricsMotion`, `ANCHOR_RATIO`/`MOTION_DURATION_MS`/`MOTION_DELAY_STEP_MS`, plus the
/// `.fs-lyrics-inner.fs-lrc p.active` `scale(1.091)` in `components.css:2158-2162`). Parameters
/// `SidecarSyncedLyricsList`/`TVLyricsStageView` apply to their per-line transform/opacity
/// animations so the motion feel matches the desktop fullscreen player.
enum SidecarLyricsMotionPolicy {
    /// `MOTION_DURATION_MS = 800` (`fullscreen-view.ts`).
    static let duration: TimeInterval = 0.8
    /// `MOTION_DELAY_STEP_MS = 40` — each line's transition is staggered by its distance from the
    /// active line (`fullscreen-view.ts`'s `applyLyricsMotion`: `dist * MOTION_DELAY_STEP_MS`).
    static let staggerStep: TimeInterval = 0.04
    /// `ANCHOR_RATIO = 0.35` — the active line sits 35% down the lyrics pane, not dead centre
    /// (`fullscreen-view.ts`).
    static let scrollAnchor = UnitPoint(x: 0.5, y: 0.35)
    /// `.fs-lyrics-inner.fs-lrc p.active { transform: ... scale(1.091); }` (`components.css:2160`).
    static let activeLineScale: CGFloat = 1.091

    /// - Parameter distance: `abs(index - activeIndex)`, as computed by callers; defensively
    ///   clamped to `>= 0` so a negative input can never yield a negative (i.e. "starts before now")
    ///   delay.
    static func staggerDelay(forDistance distance: Int) -> TimeInterval {
        TimeInterval(max(0, distance)) * staggerStep
    }

    /// Ported from Desktop's `findLyricsIndex` (`fullscreen-view.ts:366-390`): the last line whose
    /// `startTime` is `<= time`, or `-1` before the first line's timestamp (no line highlighted
    /// during an instrumental intro) and `lines.count - 1` at/after the last line's timestamp.
    /// Deliberately distinct from `LRCParser.activeLineIndex`, which other screens clamp to `0`
    /// before the first line for a different UX — the Desktop-parity panes must match Desktop exactly.
    static func activeIndex<Line: LyricsTimedLine>(in lines: [Line], at time: Double) -> Int {
        guard !lines.isEmpty else { return -1 }
        if time < lines[0].startTime { return -1 }
        var best = 0
        for (i, line) in lines.enumerated() where line.startTime <= time {
            best = i
        }
        return best
    }
}

/// Ported from Desktop's `applyLyricsMotion` cumulative top-position layout
/// (`fullscreen-view.ts:392-426`): each lyric line is positioned independently — not scrolled as a
/// group — with the base line (active, or index 0 while nothing is active yet) anchored at
/// `paneHeight * anchorRatio`, and every other line stacked above/below it by a running sum of its
/// own height plus `interBlockGap`. Pure so the rendering views can feed it measured line heights
/// and get back per-line `y` offsets to animate towards independently.
enum SidecarLyricsLayout {
    /// `INTER_BLOCK_GAP = 16` (`fullscreen-view.ts:55`).
    static let interBlockGap: CGFloat = 16
    /// `ANCHOR_RATIO = 0.35` (`fullscreen-view.ts:54`).
    static let anchorRatio: CGFloat = 0.35

    /// - Parameters:
    ///   - heights: Measured height of each line, same order/count as the rendered lines.
    ///   - baseIndex: The active line index, or `0` when nothing is active yet (Desktop:
    ///     `activeIndex >= 0 ? activeIndex : 0`); clamped into `heights.indices`.
    ///   - paneHeight: The lyrics pane's own height, used to compute the anchor Y.
    ///   - interBlockGap: Vertical gap between consecutive line blocks. Defaults to Desktop's `16`pt;
    ///     the 10-foot tvOS stage passes a larger value so lines don't crowd at TV type sizes.
    static func tops(
        heights: [CGFloat],
        baseIndex: Int,
        paneHeight: CGFloat,
        interBlockGap: CGFloat = interBlockGap
    ) -> [CGFloat] {
        guard !heights.isEmpty else { return [] }
        let anchorY = paneHeight * anchorRatio
        let b = min(max(0, baseIndex), heights.count - 1)
        var tops = [CGFloat](repeating: 0, count: heights.count)
        tops[b] = anchorY
        if b + 1 < heights.count {
            for i in (b + 1)..<heights.count {
                tops[i] = tops[i - 1] + heights[i - 1] + interBlockGap
            }
        }
        if b - 1 >= 0 {
            for i in stride(from: b - 1, through: 0, by: -1) {
                tops[i] = tops[i + 1] - heights[i] - interBlockGap
            }
        }
        return tops
    }
}

/// Guards the lyrics panes' `TimelineView(.periodic(from:by:))` tick: recomputing the interpolated
/// position at a few Hz is cheap, but writing it to `@State` unconditionally forces the whole lyric
/// `ForEach` to re-diff at that rate for as long as the screen stays on screen. Only an actual
/// change of active line should trigger that redraw.
enum SidecarActiveLineUpdatePolicy {
    static func shouldUpdate(currentIndex: Int, newIndex: Int) -> Bool {
        currentIndex != newIndex
    }
}

/// Soft top/bottom dissolve for a lyrics pane, so lines scroll into and out of view rather than
/// being hard-clipped by the pane's bounds. Originally ported 1:1 from Desktop's fullscreen lyrics
/// container (`src/renderer/styles/components.css:2072-2078`, `.fs-lyrics-container`'s
/// `mask-image: linear-gradient(to bottom, transparent 0%, black 8%, black 70%, transparent 100%)`),
/// but the app now **intentionally diverges** from that recipe: user feedback on the sidecar screen
/// ("歌詞のフェード、スパッと切れてる感じがある、もうちょっとじわじわ消えてほしい") found Desktop's
/// short, linear 8%/30%-deep ramps read as an abrupt cut rather than a dissolve on a large lyrics
/// pane. This version lengthens both ramps (top: 0–20%, bottom: 60–100%) and shapes each with four
/// intermediate stops approximating an ease-in-out opacity curve — a straight 2-stop
/// `LinearGradient` ramp reads as a hard edge close to its terminal stop because the eye is far more
/// sensitive to opacity change near full-transparent/full-opaque than a linear alpha ramp delivers;
/// front-loading small opacity deltas near the transparent end and easing into the opaque end reads
/// as a genuine gradual melt instead. See `progress/sidecar-lyrics-fade-and-bilingual.md`.
enum SidecarLyricsEdgeFade {
    /// Where the top ramp reaches full opacity (Desktop: `8%`).
    static let topOpaqueStop: CGFloat = 0.20
    /// Where the bottom ramp starts leaving full opacity (Desktop: `70%`).
    static let bottomOpaqueStop: CGFloat = 0.60

    static var gradient: LinearGradient {
        LinearGradient(
            stops: [
                // Top ramp: transparent → opaque over 0–20%, eased (ease-in-out — slow start,
                // fast middle, slow finish) rather than linear.
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.08), location: 0.05),
                .init(color: .black.opacity(0.30), location: 0.10),
                .init(color: .black.opacity(0.65), location: 0.15),
                .init(color: .black, location: topOpaqueStop),
                // Fully opaque band across the middle of the lyrics pane.
                .init(color: .black, location: bottomOpaqueStop),
                // Bottom ramp: opaque → transparent over 60–100%, mirrored easing.
                .init(color: .black.opacity(0.65), location: 0.75),
                .init(color: .black.opacity(0.30), location: 0.85),
                .init(color: .black.opacity(0.08), location: 0.93),
                .init(color: .black.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
