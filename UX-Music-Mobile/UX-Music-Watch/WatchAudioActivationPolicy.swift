import Foundation

/// Pure decision logic for whether `WatchAudioPlayerService.activateAudioSession` needs to
/// re-configure/re-activate `AVAudioSession` at all, given what the *previous* call activated.
///
/// Repeatedly calling `setCategory`/`activate` on an already-active session is unnecessary and is
/// what produced the `SessionCore.mm:631` "attempting to activate session while already active"
/// warning on the main thread observed on-device: once `.longFormAudio` has genuinely activated,
/// nothing needs to change on the next `play()`/`togglePlayPause()` call. A previous *fallback*
/// (plain `.playback`, no route-sharing policy) is different — a Bluetooth device may have
/// connected since, so it is always worth retrying `.longFormAudio` rather than assuming the
/// speaker fallback is still the best available route.
enum WatchAudioActivationPolicy {

    /// Which policy the previous `activateAudioSession` call successfully activated, if any.
    enum ActivatedPolicy: Equatable {
        case longForm
        case fallback
    }

    /// What `activateAudioSession` should do next.
    enum Plan: Equatable {
        /// Session is already active under `.longFormAudio` — skip `setCategory`/`activate`
        /// entirely and treat activation as already succeeded.
        case skip
        /// (Re-)attempt `.longFormAudio` activation.
        case attemptLongForm
    }

    /// Pure: given the same `previouslyActivated`, always returns the same `Plan`.
    static func plan(previouslyActivated: ActivatedPolicy?) -> Plan {
        previouslyActivated == .longForm ? .skip : .attemptLongForm
    }
}
