import Combine
import Foundation

/// Persists the paired `ServerConfig` (host/port/token/serverDeviceId) for the TV app. Reuses the same
/// `ServerConfig` model and `AppConstants.serverConfigKey` the iOS app uses — the mechanism
/// (JSON-encoded `Codable` in `UserDefaults`) is identical; the TV app's `UserDefaults.standard`
/// is already isolated from iOS by bundle id, so no key collision is possible on-device.
/// `defaults` is injectable so tests never touch the real `UserDefaults.standard` suite.
struct TVServerConfigStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ServerConfig {
        guard let data = defaults.data(forKey: AppConstants.serverConfigKey),
              let config = try? JSONDecoder().decode(ServerConfig.self, from: data)
        else { return ServerConfig() }
        return config
    }

    func save(_ config: ServerConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: AppConstants.serverConfigKey)
    }

    func clear() {
        defaults.removeObject(forKey: AppConstants.serverConfigKey)
    }
}

/// Lightweight observable coordinator for the TV app's discovery + pairing screens
/// (Phase 1-2). Deliberately not a port of the iOS `AppModel` — only the state this app's
/// current screens need.
@MainActor
final class TVAppModel: ObservableObject {
    @Published private(set) var pairingState: TVPairingState = .idle
    @Published private(set) var serverConfig: ServerConfig
    @Published private(set) var isStoredConnectionReady: Bool

    let discovery: LANDiscoveryService
    var urlSession: URLSession
    private let pairingClient: TVPairingClient
    private let store: TVServerConfigStore
    private var discoveryForwarding: AnyCancellable?
    /// Delay before `.paired` auto-advances to `.idle` (see `pair(with:)`). Injectable so tests
    /// can pass `0` and observe the transition without waiting on a real clock.
    private let successAdvanceDelayNanoseconds: UInt64

    init(
        discovery: LANDiscoveryService = LANDiscoveryService(),
        pairingClient: TVPairingClient = URLSessionTVPairingClient(),
        store: TVServerConfigStore = TVServerConfigStore(),
        urlSession: URLSession = RemoteLANURLSession.shared,
        successAdvanceDelayNanoseconds: UInt64 = 1_500_000_000
    ) {
        self.discovery = discovery
        self.pairingClient = pairingClient
        self.store = store
        self.urlSession = urlSession
        self.successAdvanceDelayNanoseconds = successAdvanceDelayNanoseconds
        let loadedConfig = store.load()
        self.serverConfig = loadedConfig
        self.isStoredConnectionReady = loadedConfig.token.isEmpty || !loadedConfig.isConfigured
        // `discovery` is its own `ObservableObject` — views that only hold `@ObservedObject var
        // model: TVAppModel` do not re-render on `discovery.peers` changes unless this forwards
        // them, since SwiftUI only tracks the object it directly wraps. Without this, discovered
        // peers land in `discovery.peers` but `TVHostDiscoveryView` never redraws past the
        // spinner — confirmed live in the tvOS simulator (see `progress/tvos-pairing.md`).
        discoveryForwarding = discovery.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var isPaired: Bool { !serverConfig.token.isEmpty && serverConfig.isConfigured }

    func startDiscovery() {
        discovery.start()
    }

    func stopDiscovery() {
        discovery.stop()
    }

    /// Verifies the stored desktop connection before `TVConnectedView` constructs its long-lived
    /// clients. This makes a recovered port available to every TV feature, including stream and
    /// artwork clients that receive a value-type `RemoteAPIClient` at view construction time.
    func prepareStoredConnection() async {
        guard isPaired else {
            isStoredConnectionReady = true
            return
        }
        isStoredConnectionReady = false
        do {
            _ = try await withFailover { try await $0.fetchState() }
        } catch {
            // Keep the connected screen available so its existing error handling can surface
            // endpoint failures. Authentication errors deliberately do not trigger port hunting.
        }
        isStoredConnectionReady = true
    }

    /// Executes one desktop request against the stored config. Port recovery is shared with the
    /// iOS client through `RemoteConnectionResolver`.
    func withFailover<T>(_ operation: @Sendable (RemoteAPIClient) async throws -> T) async throws -> T {
        let storedConfig = serverConfig
        let outcome = try await RemoteConnectionResolver.withFailover(
            config: storedConfig,
            session: urlSession,
            discover: { await self.storedDesktopEndpoint(for: storedConfig) },
            persistRecoveredConfig: {
                self.serverConfig = $0
                self.store.save($0)
            },
            operation: operation
        )
        if let updatedConfig = outcome.updatedConfig {
            serverConfig = updatedConfig
            store.save(updatedConfig)
        }
        return outcome.value
    }

    /// Drives the full start→(display code)→confirm flow for a selected host, matching the
    /// desktop-to-desktop pairing flow's trust model (see `TVPairingState` doc comment).
    func pair(with peer: LANDiscoveryPeer) async {
        pairingState = TVPairingReducer.reduce(pairingState, .selectedHost(displayName: peer.displayName))
        let baseURL = "http://\(peer.host):\(peer.port)"

        do {
            let started = try await pairingClient.start(
                baseURL: baseURL,
                deviceId: DeviceIdentity.deviceId,
                displayName: DeviceIdentity.displayName
            )
            pairingState = TVPairingReducer.reduce(pairingState, .startSucceeded(started))
            pairingState = TVPairingReducer.beginConfirming(pairingState)

            let confirmed = try await pairingClient.confirm(
                baseURL: baseURL,
                sessionId: started.sessionId,
                code: started.code
            )
            persistPairedConfig(peer: peer, token: confirmed.token)
            isStoredConnectionReady = true
            pairingState = TVPairingReducer.reduce(pairingState, .confirmSucceeded(deviceId: confirmed.deviceId))
            scheduleAutoAdvanceFromPairedState()
        } catch {
            if case .confirming = pairingState {
                pairingState = TVPairingReducer.reduce(pairingState, .confirmFailed(errorMessage(error)))
            } else {
                pairingState = TVPairingReducer.reduce(pairingState, .startFailed(errorMessage(error)))
            }
        }
    }

    func resetPairingFlow() {
        pairingState = TVPairingReducer.reduce(pairingState, .reset)
    }

    /// Success is otherwise a dead end: `TVPairingResultView`'s `.paired` case shows only a
    /// checkmark, and `TVRootView` only switches to `TVConnectedView` once `pairingState` is back
    /// to `.idle`. Give the user a short beat to see the confirmation, then advance automatically.
    /// Runs as its own `Task` (rather than being awaited inline in `pair(with:)`) so `pair(with:)`
    /// still returns as soon as `.paired` is reached — matching the belt-and-braces "開始" button
    /// in `TVPairingResultView`, which can also drive this same transition immediately.
    private func scheduleAutoAdvanceFromPairedState() {
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.successAdvanceDelayNanoseconds)
            if case .paired = self.pairingState {
                self.resetPairingFlow()
            }
        }
    }

    func forgetPairing() {
        store.clear()
        serverConfig = ServerConfig()
        isStoredConnectionReady = true
        pairingState = .idle
    }

    private func persistPairedConfig(peer: LANDiscoveryPeer, token: String) {
        var config = ServerConfig(
            host: peer.host,
            port: peer.port,
            token: token,
            serverDeviceId: peer.deviceId.isEmpty ? nil : peer.deviceId
        )
        config.fallbackHosts = peer.connectionHosts.filter { $0 != peer.host }
        serverConfig = config
        store.save(config)
    }

    private func storedDesktopEndpoint(for config: ServerConfig) async -> RemoteConnectionEndpoint? {
        guard let deviceId = config.serverDeviceId,
              let peer = await discovery.resolvePairedPeer(deviceId: deviceId)
        else { return nil }
        return RemoteConnectionEndpoint(host: peer.host, port: peer.port)
    }

    private func errorMessage(_ error: Error) -> String {
        switch error {
        case TVPairingError.network(let message): return message
        case TVPairingError.invalidResponse: return "サーバーからの応答が不正です。"
        default: return error.localizedDescription
        }
    }
}
