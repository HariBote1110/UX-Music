import Foundation

/// Monotonic call-generation counter used by `MusicPlayerService` to detect and discard playback
/// operations superseded by a more recent call that arrived while the current one was suspended at
/// an `await` point (e.g. two overlapping `play()` calls racing through `loadAndPlay`'s
/// `preparePlaybackSessionIfNeeded()`/`Task.yield()` suspension points).
///
/// Not thread-safe by itself — every caller in this codebase lives on `@MainActor`, where `bump()`
/// and `isCurrent(_:)` are only ever interleaved at `await` boundaries, never concurrently. Do not
/// share an instance across actors without adding synchronisation.
struct PlaybackGenerationGuard: Equatable {
    private(set) var current: UInt64 = 0

    /// Bumps and returns the new token. Call synchronously — before the first `await` — at the top
    /// of every entry point that can lead to a suspending playback operation (or that should
    /// invalidate one already in flight, such as `stop()`).
    @discardableResult
    mutating func bump() -> UInt64 {
        current &+= 1
        return current
    }

    /// Whether `token` (captured from an earlier `bump()`) is still the most recently issued one —
    /// i.e. no later call has superseded it. Call after every `await` inside the guarded chain,
    /// before mutating shared playback state.
    func isCurrent(_ token: UInt64) -> Bool {
        token == current
    }
}
