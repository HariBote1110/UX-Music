import Foundation

/// Pure state machine for Task A's stream-first playback (cache miss → immediate ADTS AAC stream
/// while the original downloads in the background — `progress/tvos-playback.md` "ストリームファー
/// スト再生" 追記). Separated from `TVSongStreamController`'s `AVFoundation`/network side effects
/// so the loading→streaming→finished/failed transitions are unit-testable, mirroring
/// `TVRelayPlaybackReducer`'s split for the relay path.
enum TVSongStreamPlaybackState: Equatable {
    /// No stream in progress (cache hit path, or nothing playing).
    case idle
    /// Cache miss: the stream request has been sent but no PCM has started rendering yet. The UI
    /// shows the loading spinner in this state (Task A's "immediate UI feedback" requirement).
    case loading
    /// PCM is actually rendering — the loading spinner should be gone.
    case streaming
    /// The stream reached the end of the HTTP body with no error — the track finished playing.
    case finished
    /// The stream failed (network error, non-2xx, unrecoverable decode failure, or startup
    /// timeout) before or during playback.
    case failed(reason: String)
}

enum TVSongStreamPlaybackEvent {
    case start
    case didStartRendering
    case didReachEndOfStream
    case fail(reason: String)
    case reset
}

enum TVSongStreamPlaybackReducer {
    static func reduce(_ state: TVSongStreamPlaybackState, event: TVSongStreamPlaybackEvent) -> TVSongStreamPlaybackState {
        switch event {
        case .start:
            return .loading
        case .didStartRendering:
            // Only a `.loading` stream can transition to `.streaming` — a stray/late callback
            // after a `.fail`/`.reset` (e.g. a torn-down player's delegate call racing the
            // teardown) must not resurrect state.
            guard state == .loading else { return state }
            return .streaming
        case .didReachEndOfStream:
            return .finished
        case .fail(let reason):
            return .failed(reason: reason)
        case .reset:
            return .idle
        }
    }

    /// Whether the loading UI (spinner) should be visible. Task A requires this to appear within
    /// ~100ms of selection on a cache miss.
    static func isLoading(_ state: TVSongStreamPlaybackState) -> Bool {
        state == .loading
    }
}

/// Pure decision: does a cache miss for `songId` warrant starting the stream-first path? The only
/// rule is "was it already cached" — everything else (loading UI, background download, EQ/gain)
/// is a consequence handled elsewhere. Extracted as its own tiny pure function so
/// `TVPlaybackController.play`'s branch is trivially testable without touching the actor-isolated
/// `TVPlaybackCacheStore`.
enum TVSongPlaybackPlan {
    static func shouldStream(cacheHit: Bool) -> Bool {
        !cacheHit
    }
}
