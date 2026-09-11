import CryptoKit
import Foundation

struct RemoteConnectionEndpoint: Equatable, Sendable {
    let host: String
    let port: Int
}

struct RemoteConnectionFailoverResult<Value> {
    let value: Value
    let updatedConfig: ServerConfig?
}

/// Shares port recovery work for requests that failed against the same stored connection.
/// Negative results are cached briefly so an offline desktop does not trigger discovery and nine
/// identity probes for every artwork, lyrics, or library request.
actor RemoteConnectionRecoveryCoordinator {
    static let shared = RemoteConnectionRecoveryCoordinator()
    static let negativeCooldownDuration: TimeInterval = 30

    private let now: @Sendable () -> TimeInterval
    private var inFlight: [String: Task<RemoteConnectionEndpoint?, Never>] = [:]
    private var negativeCooldownUntil: [String: TimeInterval] = [:]
    private var successGeneration: [String: UInt64] = [:]

    init(now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
    }

    func recover(
        for key: String,
        operation: @escaping @Sendable () async -> RemoteConnectionEndpoint?
    ) async -> RemoteConnectionEndpoint? {
        let timestamp = now()
        if let cooldownDeadline = negativeCooldownUntil[key] {
            guard timestamp >= cooldownDeadline else { return nil }
            negativeCooldownUntil[key] = nil
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let generation = successGeneration[key, default: 0]
        let task = Task { await operation() }
        inFlight[key] = task
        let endpoint = await task.value
        inFlight[key] = nil
        if endpoint == nil, successGeneration[key, default: 0] == generation {
            negativeCooldownUntil[key] = now() + Self.negativeCooldownDuration
        } else {
            negativeCooldownUntil[key] = nil
        }
        return endpoint
    }

    func markSuccessfulRequest(for key: String) {
        successGeneration[key, default: 0] &+= 1
        negativeCooldownUntil[key] = nil
    }
}

/// Pings connection candidates in order and returns the first reachable one.
///
/// Used both by the Settings "Test" button and by discovered-peer selection, so a peer is never
/// saved as the active server without having actually been reached first.
enum RemoteConnectionResolver {
    static let portRecoveryRequestTimeout: TimeInterval = 1

    /// Executes a stored desktop request, recovering a changed server port only after every
    /// stored-host attempt failed with a connection-level error. The caller supplies discovery so
    /// this shared flow can use the app's existing Bonjour service without owning its lifecycle.
    static func withFailover<Value>(
        config: ServerConfig,
        session: URLSession,
        discover: @Sendable @escaping () async -> RemoteConnectionEndpoint?,
        persistRecoveredConfig: (ServerConfig) -> Void,
        recoveryCoordinator: RemoteConnectionRecoveryCoordinator = .shared,
        operation: @Sendable (RemoteAPIClient) async throws -> Value
    ) async throws -> RemoteConnectionFailoverResult<Value> {
        let hostsToTry = ConnectionCandidatePolicy.hostsToTry(
            primaryHost: config.host,
            fallbackHosts: config.fallbackHosts,
            preferredHost: config.preferredHost
        )
        let key = recoveryKey(config: config, hosts: hostsToTry)

        var lastError: Error?
        for (index, host) in hostsToTry.enumerated() {
            let candidateConfig = ServerConfig(
                host: host,
                port: config.port,
                token: config.token,
                serverDeviceId: config.serverDeviceId
            )
            let candidateClient = RemoteAPIClient(
                baseURLString: candidateConfig.baseURLString,
                token: candidateConfig.token,
                session: session
            )
            do {
                let value = try await operation(candidateClient)
                await recoveryCoordinator.markSuccessfulRequest(for: key)
                guard index > 0 else {
                    return RemoteConnectionFailoverResult(value: value, updatedConfig: nil)
                }

                var promotedConfig = config
                var remaining = hostsToTry
                remaining.remove(at: index)
                promotedConfig.host = host
                promotedConfig.fallbackHosts = remaining
                return RemoteConnectionFailoverResult(value: value, updatedConfig: promotedConfig)
            } catch let error as URLError {
                lastError = error
            } catch {
                throw error
            }
        }

        guard config.isConfigured else {
            throw lastError ?? URLError(.cannotConnectToHost)
        }
        guard let recoveredEndpoint = await recoveryCoordinator.recover(for: key, operation: {
            let discoveredEndpoint = await discover()
            return await recoverEndpoint(
                config: config,
                hosts: hostsToTry,
                discoveredEndpoint: discoveredEndpoint,
                session: session
            )
        }) else {
            throw lastError ?? URLError(.cannotConnectToHost)
        }

        var recoveredConfig = config
        recoveredConfig.port = recoveredEndpoint.port
        if recoveredConfig.preferredHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            recoveredConfig.host = recoveredEndpoint.host
            recoveredConfig.fallbackHosts = hostsToTry.filter {
                $0.caseInsensitiveCompare(recoveredEndpoint.host) != .orderedSame
            }
        }
        let recoveredClient = RemoteAPIClient(
            baseURLString: ServerConfig(
                host: recoveredEndpoint.host,
                port: recoveredEndpoint.port,
                token: config.token,
                serverDeviceId: config.serverDeviceId
            ).baseURLString,
            token: config.token,
            session: session
        )
        persistRecoveredConfig(recoveredConfig)
        let value = try await operation(recoveredClient)
        await recoveryCoordinator.markSuccessfulRequest(for: key)
        return RemoteConnectionFailoverResult(value: value, updatedConfig: nil)
    }

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

    /// Finds a stored desktop after its old port stopped accepting connections. mDNS is supplied
    /// by the caller because the discovery service owns its browser lifecycle; only when it has no
    /// matching peer do we fan out identity probes over every known host and candidate port.
    static func recoverEndpoint(
        config: ServerConfig,
        hosts: [String],
        discoveredEndpoint: RemoteConnectionEndpoint?,
        session: URLSession,
        requestTimeout: TimeInterval = portRecoveryRequestTimeout
    ) async -> RemoteConnectionEndpoint? {
        if let discoveredEndpoint,
           !discoveredEndpoint.host.isEmpty,
           (1...65_535).contains(discoveredEndpoint.port) {
            return discoveredEndpoint
        }

        let ports = AppConstants.serverPortCandidates.filter { $0 != config.port }
        let uniqueHosts = hosts.reduce(into: [String]()) { result, host in
            let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                return
            }
            result.append(trimmed)
        }

        return await withTaskGroup(of: RemoteConnectionEndpoint?.self) { group in
            for host in uniqueHosts {
                for port in ports {
                    group.addTask {
                        let candidate = ServerConfig(
                            host: host,
                            port: port,
                            token: config.token,
                            serverDeviceId: config.serverDeviceId
                        )
                        let client = RemoteAPIClient(
                            baseURLString: candidate.baseURLString,
                            token: candidate.token,
                            session: session
                        )
                        guard let identity = try? await client.fetchIdentity(timeout: requestTimeout) else {
                            return nil
                        }

                        if let expectedDeviceId = config.serverDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !expectedDeviceId.isEmpty {
                            guard identity.deviceId == expectedDeviceId else { return nil }
                        } else {
                            // Legacy configs have no desktop ID. The identity must explicitly
                            // report a desktop role and the stored token must authorise an API call.
                            guard identity.reportsDesktopRole,
                                  await acceptsStoredToken(client: client, timeout: requestTimeout)
                            else { return nil }
                        }
                        return RemoteConnectionEndpoint(host: host, port: port)
                    }
                }
            }

            while let endpoint = await group.next() {
                if let endpoint {
                    group.cancelAll()
                    return endpoint
                }
            }
            return nil
        }
    }

    private static func recoveryKey(config: ServerConfig, hosts: [String]) -> String {
        if let deviceId = config.serverDeviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !deviceId.isEmpty {
            return "device:\(deviceId)"
        }

        let normalisedHosts = hosts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let tokenDigest = SHA256.hash(data: Data(config.token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "legacy:\(normalisedHosts.joined(separator: "\u{1f}"))|port:\(config.port)|token:\(tokenDigest)"
    }

    /// Unlike `checkAuthorised`, which intentionally treats non-auth errors as inconclusive for
    /// the Settings UI, port recovery needs a positive token verdict and therefore rejects every
    /// failure.
    private static func acceptsStoredToken(client: RemoteAPIClient, timeout: TimeInterval) async -> Bool {
        do {
            _ = try await client.fetchState(timeout: timeout)
            return true
        } catch {
            return false
        }
    }
}
