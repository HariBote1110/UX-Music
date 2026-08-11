import Combine
import Foundation

/// Persists the paired `ServerConfig` (host/port/token) for the TV app. Reuses the same
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

    let discovery: LANDiscoveryService
    private let pairingClient: TVPairingClient
    private let store: TVServerConfigStore

    init(
        discovery: LANDiscoveryService = LANDiscoveryService(),
        pairingClient: TVPairingClient = URLSessionTVPairingClient(),
        store: TVServerConfigStore = TVServerConfigStore()
    ) {
        self.discovery = discovery
        self.pairingClient = pairingClient
        self.store = store
        self.serverConfig = store.load()
    }

    var isPaired: Bool { !serverConfig.token.isEmpty && serverConfig.isConfigured }

    func startDiscovery() {
        discovery.start()
    }

    func stopDiscovery() {
        discovery.stop()
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
            pairingState = TVPairingReducer.reduce(pairingState, .confirmSucceeded(deviceId: confirmed.deviceId))
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

    func forgetPairing() {
        store.clear()
        serverConfig = ServerConfig()
        pairingState = .idle
    }

    private func persistPairedConfig(peer: LANDiscoveryPeer, token: String) {
        var config = ServerConfig(host: peer.host, port: peer.port, token: token)
        config.fallbackHosts = peer.connectionHosts.filter { $0 != peer.host }
        serverConfig = config
        store.save(config)
    }

    private func errorMessage(_ error: Error) -> String {
        switch error {
        case TVPairingError.network(let message): return message
        case TVPairingError.invalidResponse: return "サーバーからの応答が不正です。"
        default: return error.localizedDescription
        }
    }
}
