import Foundation

/// Pure decision logic for `WatchAudioPlayerService`'s two-stage `AVAudioSession` activation.
///
/// watchOS cannot play long-form audio over the built-in speaker — `.longFormAudio` route-sharing
/// policy activation only succeeds once a Bluetooth output (headphones, AirPods, a paired output)
/// is already connected. Previously, a failed `.longFormAudio` activation was treated as a hard
/// failure and surfaced as a blocking `routeError`, silently preventing playback whenever no
/// Bluetooth output was paired — even though watchOS *does* support plain `.playback` category
/// audio (with the ordinary `.default` route-sharing policy, not long-form) over the built-in
/// speaker. `WatchAudioPlayerService.activateAudioSession` now attempts `.longFormAudio` first and,
/// only if that fails, falls back to a plain `.playback`/`.default` session so audio still plays
/// through the speaker.
///
/// This type is the pure "what happened, and what does it mean" half of that decision — it holds no
/// `AVAudioSession` reference and performs no I/O, so the two-stage fallback logic is unit-testable
/// without a real audio session.
enum WatchAudioRoutePolicy {

    /// Outcome of attempting the two-stage activation.
    enum Outcome: Equatable {
        /// The `.longFormAudio` route-sharing policy activated — the expected outcome once a
        /// Bluetooth output is connected. No user-facing notice needed.
        case longForm
        /// `.longFormAudio` activation failed, but the plain `.playback`/`.default` fallback
        /// succeeded — audio plays through the Watch's built-in speaker. Callers should surface a
        /// small non-blocking notice (not `routeError`, which is reserved for total failure).
        case speakerFallback
        /// Both attempts failed — no audio output is available at all. Callers should surface
        /// `routeError` and must not start playback.
        case unavailable
    }

    /// Decides the outcome from the two independent activation attempts. Pure: given the same two
    /// booleans, always returns the same `Outcome`.
    static func outcome(longFormActivated: Bool, speakerActivated: Bool) -> Outcome {
        if longFormActivated {
            return .longForm
        }
        if speakerActivated {
            return .speakerFallback
        }
        return .unavailable
    }
}
