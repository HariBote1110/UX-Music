import Foundation

/// Where selecting `song` on the TV should send playback (`progress/tvos-relay-reception.md` 追記
/// — "route by file availability, not source": most YouTube-sourced songs are downloaded, so the
/// host serves their audio at `/v1/remote/file/{id}` exactly like any scanned file, and the TV
/// should stream them through the normal local path (EQ/LUFS, full transport, prefetch/cache,
/// play-event reporting) with no distinction from a local song. Only songs the host genuinely
/// cannot serve audio for (`Song.hasLocalAudio == false` — an embed/stream-only YouTube entry)
/// route through the desktop's own playback + LAN relay instead.
enum TVSongPlaybackRoute: Equatable {
    case local
    case viaPC
}

enum TVSongPlaybackRouting {
    static func route(for song: Song) -> TVSongPlaybackRoute {
        song.effectiveHasLocalAudio ? .local : .viaPC
    }
}

/// Pure state machine for the "PC経由で再生中" flow: the TV sent `POST /v1/remote/command`
/// (`action: "play-song"`) and is now waiting for the host to actually start relaying that YouTube
/// video before joining `TVRelayPlaybackController`/`TVRelayStreamPlayer` reception. Deliberately
/// separated from the networking/polling side effects (see `TVRemotePlaySongCoordinator`) so the
/// transitions are unit-testable without touching `RemoteAPIClient`, matching the existing
/// `TVRelayPlaybackReducer` pattern this feature reuses downstream.
enum TVRemotePlaySongState: Equatable {
    /// No remote-play attempt in progress.
    case idle
    /// `POST /v1/remote/command` (`play-song`) is in flight.
    case sending
    /// The command was accepted; polling `GET /v1/remote/state` for `relay.active` to flip true.
    case waitingForRelay
    /// `relay.active` flipped true — the caller should now start `TVRelayPlaybackController` and
    /// show the relay banner.
    case active
    /// The command failed (network error, 404 unknown song, 409 `gui_required` headless host) or
    /// the wait for `relay.active` timed out. `reason` is already localised for display.
    case failed(reason: String)
}

enum TVRemotePlaySongEvent {
    case start
    case sendSucceeded
    case sendFailed(reason: String)
    case relayActive
    case timedOut
    case exit
}

enum TVRemotePlaySongReducer {
    static func reduce(_ state: TVRemotePlaySongState, event: TVRemotePlaySongEvent) -> TVRemotePlaySongState {
        switch event {
        case .start:
            return .sending
        case .sendSucceeded:
            return .waitingForRelay
        case .sendFailed(let reason):
            return .failed(reason: reason)
        case .relayActive:
            return .active
        case .timedOut:
            return .failed(reason: String(localized: "tv.remotePlay.error.timeout"))
        case .exit:
            return .idle
        }
    }
}
