import Foundation

/// Pure state machine for `TVNowPlayingView`'s normal ⇄ ambient (screensaver-style) presentation
/// (`markdown/appletv-servermode-plan.md` Phase 2). Takes no timers/views as input — the view
/// layer supplies `isPlaying` and `secondsSinceLastInteraction`, and `next` is a total function of
/// those plus the current state. See `progress/tvos-nowplaying.md` for the timeout rationale.
enum TVAmbientStateMachine {
    enum State: Equatable {
        case normal
        case ambient
    }

    /// Seconds of no Siri Remote interaction, while playing, before switching to ambient.
    static let idleTimeout: TimeInterval = 30

    /// Any interaction (`secondsSinceLastInteraction == 0`) returns to `.normal` immediately.
    /// Ambient only ever engages while actively playing — pausing (or stopping) always resolves
    /// to `.normal` so the ambient view never lingers over silence.
    static func next(current: State, isPlaying: Bool, secondsSinceLastInteraction: TimeInterval) -> State {
        guard isPlaying else { return .normal }
        guard secondsSinceLastInteraction >= idleTimeout else { return .normal }
        return .ambient
    }
}
