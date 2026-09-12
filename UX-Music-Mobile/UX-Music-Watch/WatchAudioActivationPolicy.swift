import Foundation

/// Pure decision logic for whether `WatchAudioPlayerService.activateAudioSession` needs to
/// re-configure/re-activate `AVAudioSession` at all, given the current output preference and what
/// the *previous* call activated.
///
/// Repeatedly calling `setCategory`/`activate` on an already-active session is unnecessary and is
/// what produced the `SessionCore.mm:631` "attempting to activate session while already active"
/// warning on the main thread observed on-device: once `.longFormAudio` has genuinely activated,
/// nothing needs to change on the next `play()`/`togglePlayPause()` call. A skip is safe only when
/// the previous policy matches the policy selected by the current preference and route heuristic.
enum WatchAudioActivationPolicy {

    /// Which policy the previous `activateAudioSession` call successfully activated, if any.
    enum ActivatedPolicy: Equatable {
        case longForm
        case fallback
    }

    /// What `activateAudioSession` should do next.
    enum Plan: Equatable {
        /// Session is already active under the policy selected by the current preference.
        case skip
        /// (Re-)attempt `.longFormAudio` activation.
        case attemptLongForm
        /// (Re-)attempt plain `.playback`/`.default` activation.
        case attemptSpeaker
    }

    /// Pure: given the same activation history, preference, and route heuristic, always returns the
    /// same `Plan`.
    static func plan(
        previouslyActivated: ActivatedPolicy?,
        preference: WatchAudioOutputPreference,
        bluetoothDetected: Bool
    ) -> Plan {
        let desiredPlan: Plan
        switch preference {
        case .automatic:
            desiredPlan = bluetoothDetected ? .attemptLongForm : .attemptSpeaker
        case .bluetooth:
            desiredPlan = .attemptLongForm
        case .speaker:
            desiredPlan = .attemptSpeaker
        }

        switch (previouslyActivated, desiredPlan) {
        case (.longForm, .attemptLongForm), (.fallback, .attemptSpeaker):
            return .skip
        default:
            return desiredPlan
        }
    }
}
