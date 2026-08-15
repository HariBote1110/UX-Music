import CoreGraphics
import Foundation

/// What the ambient (idle) state actually *looks like* on `TVNowPlayingView`, as pure numbers.
/// `TVAmbientStateMachine` decides **when** ambient is engaged; this decides **how** it presents.
///
/// The original implementation swapped the entire layout for a bottom-anchored text overlay, so 30
/// seconds after the last Siri Remote input the artwork card, track info, lyrics, progress bar and
/// transport controls all left the screen at once — reported from a real Apple TV as
/// 「背景だけが残り、UIやジャケットが消えてしまう」. Ambient is now a *chrome fade* instead: the
/// artwork and lyrics stay exactly where they were, only the interactive chrome (transport buttons,
/// progress bar) fades away, and the whole content block drifts slowly so a static image never sits
/// on the same panel pixels for an entire album — which was the legitimate reason the original
/// ambient mode blanked the screen in the first place. See
/// `progress/tvos-ambient-artwork-retention.md`.
enum TVAmbientPresentation {
    /// Cross-fade length between the normal and ambient presentations. Deliberately slow — the
    /// transition should read as the room lights dimming, not as a screen change.
    static let transitionDuration: TimeInterval = 1.2

    /// How far the content block is dimmed in ambient. Must stay comfortably above zero: the whole
    /// point of the fix is that the artwork remains readable from the sofa.
    static let ambientContentOpacity: Double = 0.82

    /// Peak excursion (points, per axis) of the slow burn-in drift.
    static let driftRadius: CGFloat = 28

    /// Seconds for one full drift figure. Long enough that the movement is never perceptible as
    /// motion, short enough that no pixel holds the same content for more than about a minute.
    static let driftPeriod: TimeInterval = 120

    /// Opacity of the artwork/track-info/lyrics block.
    static func contentOpacity(ambient: Bool) -> Double {
        ambient ? ambientContentOpacity : 1
    }

    /// Opacity of the interactive chrome (transport bar, progress bar and its time labels), which is
    /// the only thing ambient actually removes.
    static func chromeOpacity(ambient: Bool) -> Double {
        ambient ? 0 : 1
    }

    /// Slow Lissajous drift applied to the content block while ambient, mitigating OLED burn-in now
    /// that the artwork stays on screen indefinitely. Both axes are zero at
    /// `secondsSinceAmbientStart == 0`, so engaging ambient never jumps the layout; the vertical
    /// axis runs at twice the horizontal frequency (and half the amplitude) so the path traces a
    /// figure-of-eight rather than retracing one line.
    static func driftOffset(ambient: Bool, secondsSinceAmbientStart: TimeInterval) -> CGSize {
        guard ambient else { return .zero }
        let elapsed = max(0, secondsSinceAmbientStart)
        let phase = 2 * Double.pi * elapsed / driftPeriod
        return CGSize(
            width: driftRadius * CGFloat(sin(phase)),
            height: driftRadius * 0.5 * CGFloat(sin(2 * phase))
        )
    }
}
