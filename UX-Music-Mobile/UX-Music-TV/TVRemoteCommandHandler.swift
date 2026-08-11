import Foundation

/// Pure request→action mapping for the TV's own `/v1/remote/command` receiver
/// (`markdown/appletv-servermode-plan.md` §3-1). Mirrors the desktop's action vocabulary
/// (`server/app_remote.go`'s `remoteCommandHandler`: `toggle`/`play`/`pause`/`seek`/`next`/`prev`)
/// so the iOS Remote tab's existing command-sending code (`RemoteAPIClient.sendCommand`) works
/// against a TV target with zero changes on the iOS side — only the base URL/token differ.
/// `volume` is added because `MusicPlayerService.masterVolume` exists on TV even though the
/// desktop dialect doesn't expose a volume action (desktop volume is host-local, not remoted).
///
/// No `MusicPlayerService`/networking here — the actual dispatch onto the player lives in
/// `TVRemoteControlServer`, which stays a thin adapter around this.
enum TVRemoteCommandHandler {
    enum Action: Equatable {
        case toggle
        case play
        case pause
        case next
        case previous
        case seek(Double)
        case volume(Double)
    }

    enum ResolutionError: Error, Equatable {
        /// `seek`/`volume` require a numeric `value` in the request body.
        case missingValue
        /// Anything outside the supported vocabulary — surfaced to the caller as a documented
        /// error rather than silently ignored (§3-1: "unsupported commands → documented error").
        case unsupportedAction(String)
    }

    static func resolve(action: String, value: Double?) -> Result<Action, ResolutionError> {
        switch action {
        case "toggle": return .success(.toggle)
        case "play": return .success(.play)
        case "pause": return .success(.pause)
        case "next": return .success(.next)
        case "prev", "previous": return .success(.previous)
        case "seek":
            guard let value else { return .failure(.missingValue) }
            return .success(.seek(value))
        case "volume":
            guard let value else { return .failure(.missingValue) }
            return .success(.volume(value))
        default:
            return .failure(.unsupportedAction(action))
        }
    }
}

/// Pure builder for the JSON body of `GET /v1/remote/state` as served by the TV, matching the
/// desktop's `remoteStateHandler` key set (`position`/`duration`/`playing`/`title`/`artist`/
/// `album`) plus a TV-only `volume` key. Takes primitive values rather than a `MusicPlayerService`
/// so it stays synchronous/testable without touching `AVAudioEngine`.
enum TVRemoteStateBuilder {
    static func state(
        title: String,
        artist: String,
        album: String,
        position: Double,
        duration: Double,
        playing: Bool,
        volume: Double
    ) -> [String: Any] {
        [
            "title": title,
            "artist": artist,
            "album": album,
            "position": position,
            "duration": duration,
            "playing": playing,
            "paused": !playing,
            "volume": volume,
        ]
    }
}

/// Pure bearer-token check for the TV receiver's auth (§3-1: "require the SAME device token the
/// TV obtained at pairing"). Matches the desktop's `Authorization: Bearer <token>` convention
/// (`RemoteAPIClient.authorizedRequest`) rather than inventing a new scheme.
enum TVRemoteAuth {
    static func isAuthorized(authorizationHeader: String?, expectedToken: String) -> Bool {
        guard !expectedToken.isEmpty else { return false }
        guard let header = authorizationHeader, header.hasPrefix("Bearer ") else { return false }
        let presented = String(header.dropFirst("Bearer ".count))
        return presented == expectedToken
    }
}

/// Pure builder for `GET /v1/identity` on the TV receiver — same shape as the desktop's
/// `/v1/identity` (`hostname`/`roles`) but `roles` is always `["tv"]` (§3-1).
enum TVIdentityPayload {
    static func json(deviceName: String) -> [String: Any] {
        ["hostname": deviceName, "roles": ["tv"]]
    }
}
