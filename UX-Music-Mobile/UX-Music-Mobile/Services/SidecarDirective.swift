import Foundation
import SwiftUI
import UIKit

/// Parsed "sidecar" directive from `GET /v1/remote/state`'s `"sidecar": {"active": Bool}` field,
/// plus the optional top-level `songId`/`artworkId` strings the desktop may include so
/// `SidecarScreen` can resolve artwork directly instead of falling back to fuzzy title/artist
/// matching (as `RemoteControlScreen`'s `RemoteArtworkCard` does).
struct SidecarDirective: Equatable, Sendable {
    var active: Bool
    var songId: String?
    var artworkId: String?

    static let inactive = SidecarDirective(active: false, songId: nil, artworkId: nil)

    /// Parses a raw `/v1/remote/state` JSON dictionary (`[String: Any]`, as produced by
    /// `JSONSerialization` in `RemoteAPIClient.fetchState`). Defensive by design: a missing
    /// `sidecar` key, a non-dictionary value, a missing/non-Bool `active`, or `active == false`
    /// all resolve to `.inactive` rather than throwing.
    static func parse(from state: [String: Any]) -> SidecarDirective {
        guard let sidecar = state["sidecar"] as? [String: Any],
              let active = sidecar["active"] as? Bool,
              active
        else {
            return .inactive
        }
        return SidecarDirective(
            active: true,
            songId: nonEmptyString(state["songId"]),
            artworkId: nonEmptyString(state["artworkId"])
        )
    }

    private static func nonEmptyString(_ any: Any?) -> String? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return s
    }
}

/// Interpolates the sidecar's playback position between 2s poll ticks so the progress bar keeps
/// animating smoothly (see `AppModel`'s sidecar poller, which stamps `sidecarPositionTimestamp` on
/// every successful fetch).
enum SidecarProgressInterpolation {
    /// - Parameters:
    ///   - position: last-known `position` (seconds) reported by the desktop.
    ///   - timestamp: wall-clock time `position` was captured at.
    ///   - playing: whether playback was running as of `timestamp`; when `false` the position is
    ///     returned unchanged (no drift while paused).
    ///   - now: the wall-clock time to interpolate to.
    ///   - duration: track duration (seconds); the result is clamped to `[0, duration]` when
    ///     `duration > 0`, and clamped to `>= 0` otherwise.
    static func interpolatedPosition(position: Double, timestamp: Date, playing: Bool, now: Date, duration: Double) -> Double {
        guard playing else { return position }
        let elapsed = now.timeIntervalSince(timestamp)
        guard elapsed > 0 else { return position }
        let interpolated = position + elapsed
        guard duration > 0 else { return max(0, interpolated) }
        return min(max(0, interpolated), duration)
    }
}

/// Local-dismiss suppression for the sidecar fullscreen cover: tapping its close button while
/// `active == true` should keep the cover dismissed until the desktop directive goes false and
/// then true again (a fresh sidecar session), even though the poller keeps reporting
/// `active == true` in the meantime.
enum SidecarPresentationPolicy {
    /// Whether the fullscreen cover should currently be shown.
    static func shouldPresent(active: Bool, locallyDismissed: Bool) -> Bool {
        active && !locallyDismissed
    }

    /// Whether a fresh `active` reading should clear a previous local dismissal — true only on the
    /// false → true transition (a new sidecar session started on the desktop).
    static func shouldClearDismissal(previousActive: Bool, newActive: Bool) -> Bool {
        !previousActive && newActive
    }
}

/// Everything about the current sidecar track other than playback position — the fields that
/// realistically stay constant for dozens of consecutive 2s poll ticks while a track plays.
/// `AppModel`'s poller compares snapshots and only writes its `@Observable` properties when this
/// changes, so views that read those properties (e.g. `SidecarArtworkView`, the title/artist
/// labels) are not invalidated every tick for no reason. `position`/`positionTimestamp` are
/// deliberately kept outside this snapshot — they must be written every successful tick regardless
/// of value so `SidecarProgressInterpolation` keeps a fresh wall-clock anchor.
struct SidecarMetadataSnapshot: Equatable {
    var songId: String?
    var artworkId: String?
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var playing: Bool
}

/// Decides the app-wide supported-orientation mask while `SidecarScreen` is/isn't presented. Kept
/// pure and separate from `AppDelegate` so the decision is unit-testable without a UIKit runtime.
enum SidecarOrientationPolicy {
    /// `.landscape` while the sidecar's fullscreen cover is on screen (it is landscape-first —
    /// large artwork beside synced lyrics), `defaultMask` otherwise.
    ///
    /// `defaultMask` MUST match Info.plist's `UISupportedInterfaceOrientations` for the current
    /// idiom exactly (see `SidecarOrientationLock.defaultMask`). Returning a broader mask than
    /// Info.plist declares (e.g. `.all`, which includes portrait-upside-down on iPhone even though
    /// Info.plist's `~iphone` key excludes it) makes UIKit's declared-supported set disagree with
    /// itself on every geometry query, which drives BackBoardServices into a continuous
    /// frame-invalidation loop (BLSInvalidateFrameSpecifiersAction) — visible as runaway CPU/RSS
    /// growth even while the sidecar is never shown, because the mismatch exists from launch.
    static func mask(sidecarPresented: Bool, defaultMask: UIInterfaceOrientationMask) -> UIInterfaceOrientationMask {
        sidecarPresented ? .landscape : defaultMask
    }
}

/// Decides whether `SidecarScreen`'s chrome (close button, elapsed/remaining time labels) is
/// visible: shown right after any tap, faded out after a few seconds of inactivity so the display
/// stays glanceable/ambient. The progress bar itself stays visible regardless — only the labels and
/// close button fold into this "idle elegance" behaviour.
enum SidecarChromeVisibilityPolicy {
    static let defaultIdleThreshold: TimeInterval = 5

    /// - Parameters:
    ///   - lastInteraction: wall-clock time of the most recent tap (or screen appearance).
    ///   - now: the wall-clock time to evaluate visibility at.
    ///   - idleThreshold: seconds of inactivity after which the chrome fades out.
    static func isVisible(lastInteraction: Date, now: Date, idleThreshold: TimeInterval = defaultIdleThreshold) -> Bool {
        now.timeIntervalSince(lastInteraction) < idleThreshold
    }
}

/// Computes the artwork's square side length for `SidecarScreen`'s left column, guaranteeing a
/// perfect square (no letterboxing bars) regardless of the column's own aspect ratio: the square is
/// capped by whichever of the column's width/height (after margins) is shorter, and never exceeds
/// `maxSide`. Kept pure so the sizing decision is unit-testable without a `GeometryReader` runtime.
enum SidecarArtworkLayout {
    static func squareSide(columnWidth: CGFloat, columnHeight: CGFloat, margin: CGFloat, maxSide: CGFloat) -> CGFloat {
        let shorter = min(columnWidth, columnHeight) - margin
        return min(max(0, shorter), maxSide)
    }
}

/// Ported from Desktop's fullscreen lyrics motion (`src/renderer/js/features/fullscreen-view.ts`'s
/// `applyLyricsMotion`, `ANCHOR_RATIO`/`MOTION_DURATION_MS`/`MOTION_DELAY_STEP_MS`, plus the
/// `.fs-lyrics-inner.fs-lrc p.active` `scale(1.091)` in `components.css:2158-2162`). Parameters
/// `SidecarSyncedLyricsList` applies to its `ScrollViewReader.scrollTo` and per-line
/// transform/opacity animations so the motion feel matches the desktop fullscreen player instead of
/// the previous flat 0.35s ease-out scroll.
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
}

/// Ported from Desktop's fullscreen overlay background recipe (`src/renderer/styles/components.css`
/// lines 1764-1776, `.fs-overlay`): a two-stop 135° linear gradient between the artwork's two
/// dominant colours, each mixed 30% into a near-black base (`#0e0e1a`) via CSS `color-mix`, with a
/// 1.2s ease transition whenever the colours change (on track change). Kept pure/testable — the
/// `Color` construction and the 1.2s `.animation(...)` live in `SidecarScreen`'s view code.
enum SidecarBackgroundGradient {
    /// `#0e0e1a` in 0…1 sRGB — the near-black `color-mix` base from `components.css:1770-1771`.
    static let mixBase: (Double, Double, Double) = (14.0 / 255.0, 14.0 / 255.0, 26.0 / 255.0)
    /// The `30%` in `color-mix(in srgb, var(--fs-bg-N) 30%, #0e0e1a)`.
    static let mixRatio: Double = 0.30
    /// `transition: background 1.2s ease` (`components.css:1776`).
    static let transitionDuration: TimeInterval = 1.2

    /// Mixes an artwork swatch `ratio` of the way towards `mixBase`, matching CSS `color-mix`'s
    /// linear per-channel blend (`result = swatch * ratio + base * (1 - ratio)`).
    static func mixedStop(
        from swatch: (Double, Double, Double),
        ratio: Double = mixRatio,
        base: (Double, Double, Double) = mixBase
    ) -> (Double, Double, Double) {
        let clampedRatio = min(1, max(0, ratio))
        return (
            swatch.0 * clampedRatio + base.0 * (1 - clampedRatio),
            swatch.1 * clampedRatio + base.1 * (1 - clampedRatio),
            swatch.2 * clampedRatio + base.2 * (1 - clampedRatio)
        )
    }
}

/// Guards `SidecarSyncedLyricsList`'s `TimelineView(.periodic(from:by: 0.2))` tick: recomputing the
/// interpolated position at 5Hz is cheap, but writing it to `@State` unconditionally forces the
/// whole lyric `ForEach` to re-diff 5x/sec for as long as the sidecar screen stays on screen. Only
/// an actual change of active line should trigger that redraw.
enum SidecarActiveLineUpdatePolicy {
    static func shouldUpdate(currentIndex: Int, newIndex: Int) -> Bool {
        currentIndex != newIndex
    }
}
