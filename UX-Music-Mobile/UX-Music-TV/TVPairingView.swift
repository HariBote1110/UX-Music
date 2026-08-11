import SwiftUI

/// Root shell for Phase 1-2: host discovery → pairing (large 6-digit code) → connected state.
/// Replaces `TVPlaceholderView` as the app's entry point.
struct TVRootView: View {
    @StateObject private var model = TVAppModel()

    var body: some View {
        Group {
            if model.isPaired, case .idle = model.pairingState {
                TVConnectedView(model: model)
            } else {
                TVHostDiscoveryView(model: model)
            }
        }
        .onAppear { model.startDiscovery() }
        .onDisappear { model.stopDiscovery() }
    }
}

/// Discovers hosts via mDNS (`LANDiscoveryService`, `_uxmusic-sync._tcp`) and lets the user pick
/// one to pair with. Focus-friendly list for the Siri Remote.
struct TVHostDiscoveryView: View {
    @ObservedObject var model: TVAppModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("UX Music を選択")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.pairingState {
        case .idle:
            hostList
        case .starting, .awaitingConfirmation, .confirming:
            TVPairingCodeView(state: model.pairingState)
        case .paired:
            TVPairingResultView(state: model.pairingState) { model.resetPairingFlow() }
        case .failed:
            TVPairingResultView(state: model.pairingState) { model.resetPairingFlow() }
        }
    }

    private var hostList: some View {
        VStack(spacing: 32) {
            Text("同じネットワーク上の UX Music を検索しています")
                .font(.title3)
                .foregroundStyle(.secondary)

            if model.discovery.peers.isEmpty {
                ProgressView()
            } else {
                List(model.discovery.peers) { peer in
                    Button {
                        Task { await model.pair(with: peer) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(peer.displayName).font(.headline)
                                Text(peer.endpointDescription).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding()
    }
}

/// Full-screen large 6-digit pairing code, shown while `start`/`confirm` are in flight.
struct TVPairingCodeView: View {
    let state: TVPairingState

    var body: some View {
        VStack(spacing: 40) {
            Text(hostDisplayName)
                .font(.title2)
                .foregroundStyle(.secondary)

            if let code = code {
                Text(code)
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .kerning(12)
            } else {
                ProgressView()
            }

            Text(statusText)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var hostDisplayName: String {
        switch state {
        case .starting(let name), .awaitingConfirmation(let name, _), .confirming(let name, _):
            return name
        default:
            return ""
        }
    }

    private var code: String? {
        switch state {
        case .awaitingConfirmation(_, let start), .confirming(_, let start):
            return start.code
        default:
            return nil
        }
    }

    private var statusText: String {
        switch state {
        case .starting:
            return "コードを取得しています…"
        case .awaitingConfirmation, .confirming:
            return "ペアリングを確定しています…"
        default:
            return ""
        }
    }
}

/// Success or failure terminal state, with a button to try again.
struct TVPairingResultView: View {
    let state: TVPairingState
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            switch state {
            case .paired(let hostDisplayName, _):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)
                Text("\(hostDisplayName) とペアリングしました")
                    .font(.title2)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.yellow)
                Text("ペアリングに失敗しました")
                    .font(.title2)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button("もう一度試す", action: onRetry)
            default:
                EmptyView()
            }
        }
        .padding()
    }
}

/// Shown once a host token is persisted and no new pairing flow is active. Hosts the Phase 1-3/1-4
/// browse + playback UI (`TVBrowseView`) built against the paired `RemoteAPIClient`.
struct TVConnectedView: View {
    @ObservedObject var model: TVAppModel
    @StateObject private var browseModel: TVBrowseModel
    @StateObject private var playbackController: TVPlaybackController
    @StateObject private var relayModel: TVRelayModel
    @StateObject private var relayPlaybackController: TVRelayPlaybackController
    private let player: MusicPlayerService
    private let client: RemoteAPIClient
    private let remoteControlServer: TVRemoteControlServer

    init(model: TVAppModel) {
        self.model = model
        let config = model.serverConfig
        let baseURL = "http://\(config.activeHost):\(config.port)"
        let apiClient = RemoteAPIClient(baseURLString: baseURL, token: config.token)
        self.client = apiClient
        let sharedPlayer = MusicPlayerService()
        _browseModel = StateObject(wrappedValue: TVBrowseModel(client: apiClient))
        player = sharedPlayer
        _playbackController = StateObject(
            wrappedValue: TVPlaybackController(client: apiClient, player: sharedPlayer)
        )
        // Phase 3-3 (TV side): YouTube LAN relay reception — see `progress/tvos-relay-reception.md`.
        _relayModel = StateObject(wrappedValue: TVRelayModel(client: apiClient))
        _relayPlaybackController = StateObject(wrappedValue: TVRelayPlaybackController(client: apiClient))
        // Phase 3-2: report natural track completions to the host for playcount convergence.
        let reporter = TVPlayEventReporter(client: apiClient)
        sharedPlayer.onTrackNaturallyFinished = { song in
            reporter.report(song: song)
        }
        // Phase 3-1 (TV side): let this TV itself be picked as a Connect-style playback target.
        // Security fix (`progress/tvos-connect.md` 2026-08-12 追記): authenticate with — and
        // advertise — this TV's own control token, NEVER the host pairing token (`config.token`),
        // so the mDNS broadcast can't leak a credential that grants Host library access.
        remoteControlServer = TVRemoteControlServer(
            player: sharedPlayer,
            token: TVControlTokenStore().loadOrCreate(),
            deviceName: DeviceIdentity.displayName
        )
    }

    var body: some View {
        TVBrowseView(
            browseModel: browseModel,
            playbackController: playbackController,
            relayModel: relayModel,
            relayPlaybackController: relayPlaybackController,
            player: player,
            client: client,
            onSignOut: { model.forgetPairing() }
        )
        .task {
            remoteControlServer.start()
            relayModel.startPolling()
        }
        .onDisappear {
            remoteControlServer.stop()
            relayModel.stopPolling()
            relayPlaybackController.stop()
        }
    }
}

#Preview {
    TVRootView()
}
