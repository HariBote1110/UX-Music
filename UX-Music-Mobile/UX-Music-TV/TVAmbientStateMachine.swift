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

    /// What a Menu/Back (`onExitCommand`) press should do, given the current presentation. This is
    /// the two-step exit: from `.ambient`, Menu only wakes the screen back to `.normal` (matching
    /// any other interaction); only a Menu press while already `.normal` dismisses the Now Playing
    /// screen back to browse. Without this split, a single Menu press fired while the screensaver
    /// was up would both drop ambient *and* dismiss in the same gesture, which reads as the screen
    /// vanishing without warning and risks a rapid second Menu press falling through to the tvOS
    /// home screen instead of browse.
    enum ExitAction: Equatable {
        case returnToNormal
        case dismissScreen
    }

    static func exitCommand(current: State) -> ExitAction {
        current == .ambient ? .returnToNormal : .dismissScreen
    }
}
