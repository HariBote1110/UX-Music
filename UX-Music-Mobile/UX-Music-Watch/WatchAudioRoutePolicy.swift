import Foundation

/// Pure decision logic for `WatchAudioPlayerService`'s audio-output activation attempts.
///
/// watchOS cannot play long-form audio over the built-in speaker — `.longFormAudio` route-sharing
/// policy activation only succeeds once a Bluetooth output (headphones, AirPods, a paired output)
/// is already connected. Previously, a failed `.longFormAudio` activation was treated as a hard
/// failure and surfaced as a blocking `routeError`, silently preventing playback whenever no
/// Bluetooth output was paired — even though watchOS *does* support plain `.playback` category
/// audio (with the ordinary `.default` route-sharing policy, not long-form) over the built-in
/// speaker. The user's preference controls whether `.longFormAudio` is attempted, and automatic
/// mode only attempts it when a Bluetooth route was detected before activation.
///
/// This type is the pure "what should be attempted, and what happened" half of that decision — it
/// holds no `AVAudioSession` reference and performs no I/O, so the route plan is unit-testable
/// without a real audio session.
enum WatchAudioRoutePolicy {

    /// The AVAudioSession activation policies that can be attempted, in order.
    enum Attempt: Equatable {
        case longForm
        case speaker
    }

    /// Returns the activation attempts for a preference and the pre-activation route heuristic.
    /// Pure: given the same inputs, always returns the same ordered attempts.
    static func attempts(
        preference: WatchAudioOutputPreference,
        bluetoothDetected: Bool
    ) -> [Attempt] {
        switch preference {
        case .automatic:
            return bluetoothDetected ? [.longForm, .speaker] : [.speaker]
        case .bluetooth:
            return [.longForm]
        case .speaker:
            return [.speaker]
        }
    }

    /// Outcome of the selected activation attempts.
    enum Outcome: Equatable {
        /// The `.longFormAudio` route-sharing policy activated — the expected outcome once a
        /// Bluetooth output is connected. No user-facing notice needed.
        case longForm
        /// `.longFormAudio` activation failed, but the plain `.playback`/`.default` fallback
        /// succeeded — audio plays through the Watch's built-in speaker. Callers should surface a
        /// small non-blocking notice (not `routeError`, which is reserved for total failure).
        case speakerFallback
        /// All selected attempts failed — no audio output is available at all. Callers should surface
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
