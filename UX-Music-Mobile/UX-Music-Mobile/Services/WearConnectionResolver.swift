import Foundation

/// Pings connection candidates in order and returns the first reachable one.
///
/// Used both by the Settings "Test" button and by discovered-peer selection, so a peer is never
/// saved as the active server without having actually been reached first.
enum WearConnectionResolver {
    /// Pings each candidate in order and returns the first reachable config (with the server's
    /// reported name), or `nil` if none respond. Stops pinging as soon as a candidate succeeds.
    static func resolve(
        candidates: [ServerConfig],
        ping: @Sendable (ServerConfig) async throws -> String
    ) async -> (config: ServerConfig, serverName: String)? {
        // Red-phase stub: not yet implemented.
        nil
    }
}
