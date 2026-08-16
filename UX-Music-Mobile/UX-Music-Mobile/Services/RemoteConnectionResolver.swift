import Foundation

/// Pings connection candidates in order and returns the first reachable one.
///
/// Used both by the Settings "Test" button and by discovered-peer selection, so a peer is never
/// saved as the active server without having actually been reached first.
enum RemoteConnectionResolver {
    /// Pings each candidate in order and returns the first reachable config (with the server's
    /// reported name), or `nil` if none respond. Stops pinging as soon as a candidate succeeds.
    static func resolve(
        candidates: [ServerConfig],
        ping: @Sendable (ServerConfig) async throws -> String
    ) async -> (config: ServerConfig, serverName: String)? {
        for candidate in candidates {
            if let name = try? await ping(candidate) {
                return (candidate, name)
            }
        }
        return nil
    }

    /// `ping` succeeding only proves the desktop is reachable — `GET /v1/identity` is exempt from
    /// auth, but every other endpoint requires the device token. This distinguishes "reachable, no/
    /// invalid token" (401) from "reachable and authorised" so Settings can tell the user to re-pair.
    static func checkAuthorised(client: RemoteAPIClient) async -> Bool {
        do {
            _ = try await client.fetchState()
            return true
        } catch RemoteAPIError.httpStatus(401) {
            return false
        } catch RemoteAPIError.server(let code, _) where code == "unauthorized" {
            return false
        } catch {
            // Any other error (offline, timeout, malformed response, …) is not an auth verdict —
            // treat it as "not disproven" rather than misreporting it as an auth failure.
            return true
        }
    }
}
