import Foundation

/// Pure state machine for the relay (YouTube) playback lifecycle — introduced to fix the "relay
/// failure wedges ALL playback" report (`progress/tvos-relay-reception.md`). Deliberately
/// separated from `TVRelayPlaybackController`'s `AVPlayer` side effects so the start/fail/exit →
/// player-usable transitions are unit-testable without `AVFoundation`.
enum TVRelayPlaybackState: Equatable {
    /// No relay attempt in progress. Local `MusicPlayerService` playback is fully usable.
    case idle
    /// Relay `AVPlayer` is active; the browse UI has already stopped local playback for this.
    case playing
    /// The relay attempt failed (decode error, network error, or the ~8s startup timeout) and has
    /// been torn down. Local playback is usable again — this is the state that used to be
    /// missing, leaving the app stuck as if still `.playing`.
    case failed(reason: String)
}

enum TVRelayPlaybackEvent {
    case start
    case fail(reason: String)
    case exit
}

enum TVRelayPlaybackReducer {
    static func reduce(_ state: TVRelayPlaybackState, event: TVRelayPlaybackEvent) -> TVRelayPlaybackState {
        switch event {
        case .start:
            return .playing
        case .fail(let reason):
            return .failed(reason: reason)
        case .exit:
            return .idle
        }
    }

    /// Whether local `MusicPlayerService` playback should be considered usable in `state`. `.idle`
    /// and `.failed` are both usable — the fix's key invariant is that a relay failure (or exiting
    /// the relay banner) always restores local playback, never leaves it blocked.
    static func isLocalPlaybackUsable(_ state: TVRelayPlaybackState) -> Bool {
        switch state {
        case .idle, .failed:
            return true
        case .playing:
            return false
        }
    }
}
