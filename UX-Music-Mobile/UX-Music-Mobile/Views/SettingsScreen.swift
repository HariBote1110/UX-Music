import SwiftUI

/// Whether Settings should try every known host in order ("automatic", current/legacy behaviour)
/// or only ever connect to one host the user pinned ("fixed" — e.g. a Tailscale address while
/// away from home). Mirrors `ServerConfig.preferredHost` (nil ⇔ `.automatic`).
enum ConnectionSelectionMode: Hashable {
    case automatic
    case fixed
}

/// Per-row reachability probe result for the known-hosts list (`GET /v1/identity`).
private enum HostReachability {
    case checking
    case reachable
    case unreachable
}

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var hostText = ""
    @State private var portText = ""
    /// One-time pairing code (`secret` from the QR/deep link, or typed in manually). Redeemed via
    /// `AppModel.redeemPairing` on Save/Test; cleared once redeemed since it is single-use.
    @State private var secretText = ""
    @State private var pingResult: String?
    @State private var testing = false
    @State private var savedFlash = false
    @State private var showQRScanner = false
    @State private var showDesktopPlaylistImport = false
    @State private var selectedDiscoveryPeer: LANDiscoveryPeer?
    @StateObject private var discovery = LANDiscoveryService()
    @FocusState private var focusedField: Field?

    /// Auto vs fixed connection mode, mirrored from `model.serverConfig.preferredHost` on appear.
    @State private var connectionMode: ConnectionSelectionMode = .automatic
    /// Reachability probe result per known host string (see `HostReachability`), keyed by host.
    @State private var hostReachability: [String: HostReachability] = [:]

    private enum Field {
        case host, port, secret
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("接続先")
                        Spacer()
                        Text("\(model.serverConfig.activeHost)（\(connectionMode == .fixed ? "固定" : "自動")）")
                            .foregroundStyle(.secondary)
                    }

                    Picker("接続モード", selection: $connectionMode) {
                        Text("自動（推奨）").tag(ConnectionSelectionMode.automatic)
                        Text("固定").tag(ConnectionSelectionMode.fixed)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: connectionMode) { _, newMode in
                        if newMode == .automatic {
                            model.serverConfig.preferredHost = nil
                        }
                    }

                    if model.serverConfig.allKnownHosts.isEmpty {
                        Text("既知のホストがありません。ペアリングまたは Discovery で接続すると候補が表示されます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.serverConfig.allKnownHosts, id: \.self) { knownHost in
                            Button {
                                selectKnownHost(knownHost)
                            } label: {
                                knownHostRow(knownHost)
                            }
                        }
                    }
                } header: {
                    Text("接続先の選択")
                } footer: {
                    Text(connectionMode == .fixed
                        ? "固定モードでは選んだホストにのみ接続し、失敗しても他の候補への自動切り替えは行いません。"
                        : "自動モードでは上から順に到達できるホストを探し、成功したホストを優先接続先として記憶します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("192.168.1.100", text: $hostText)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .host)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .port }

                    TextField("8765", text: $portText)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .port)

                    TextField("ペアリングコード（secret）", text: $secretText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .secret)
                } header: {
                    Text("SERVER")
                } footer: {
                    Text("デスクトップの UX Music → 設定 のペアリング QR に表示されるコード。QR をスキャンすると自動的に入力・交換されます。手入力した場合は Save か Test を押すとデバイス用トークンに交換されます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if PairingQRScannerView.isCameraAvailable {
                        Button("Pair with QR code") {
                            showQRScanner = true
                        }
                    } else {
                        Text("QR pairing needs a device with a camera.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("PAIRING")
                }

                Section {
                    if discovery.isBrowsing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching for UX Music on this network...")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if discovery.peers.isEmpty {
                        Text("No desktop found yet. Keep UX Music open on the same Wi-Fi network.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(discovery.peers) { peer in
                            Button {
                                selectDiscoveredPeer(peer)
                            } label: {
                                discoveredPeerRow(peer)
                            }
                        }
                    }

                    Button("Search again") {
                        discovery.start()
                    }

                    if let message = discovery.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("DISCOVERY")
                }

                Section {
                    HStack {
                        Text("接続状態")
                        Spacer()
                        Text(watchActivationStatusText(model.watchTransferBridge.activationStatus))
                            .foregroundStyle(watchActivationStatusColor(model.watchTransferBridge.activationStatus))
                    }
                    HStack {
                        Text("ペアリング状態")
                        Spacer()
                        Text(model.watchTransferBridge.isPaired ? "ペアリング済み" : "未ペアリング")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Watch アプリ")
                        Spacer()
                        Text(model.watchTransferBridge.isWatchAppInstalled ? "インストール済み" : "未インストール")
                            .foregroundStyle(.secondary)
                    }
                    if model.watchTransferBridge.queue.isEmpty {
                        Text("転送済みの曲はありません。ローカルライブラリの曲を長押しして「Apple Watch に転送」を選んでください。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.watchTransferBridge.queue) { item in
                            HStack {
                                Text(item.title)
                                    .lineLimit(1)
                                Spacer()
                                Text(watchTransferStatusText(item.phase))
                                    .font(.footnote)
                                    .foregroundStyle(watchTransferStatusColor(item.phase))
                            }
                        }
                    }
                } header: {
                    Text("APPLE WATCH")
                }

                Section {
                    Picker("ダウンロード音質", selection: Bindable(model).downloadAudioQuality) {
                        ForEach(DownloadAudioQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("ダウンロード")
                } footer: {
                    Text("AAC は約 1/7 のサイズで Apple Watch への転送が速いです。「フル + AAC」なら再生はフル音質、Watch 転送には AAC が使われます。既にダウンロード済みの曲には遡って適用されません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("デスクトップのプレイリストを取り込む") {
                        showDesktopPlaylistImport = true
                    }
                    .disabled(!model.serverConfig.isConfigured)
                    if !model.serverConfig.isConfigured {
                        Text("ホスト名を入力して保存すると、デスクトップのプレイリストをこの端末にコピーできます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("PLAYLISTS")
                }

                Section {
                    HStack(spacing: 10) {
                        Button(savedFlash ? "Saved ✓" : "Save") {
                            Task { await save() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(testing)

                        Button("Test") {
                            Task { await testConnection() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(testing)
                        .overlay {
                            if testing { ProgressView() }
                        }
                    }
                    .listRowBackground(Color.clear)

                    if let pingResult {
                        Text(pingResult)
                            .font(.footnote)
                            .foregroundStyle(
                                pingResult.hasPrefix("Connected") && !pingResult.hasPrefix("Connected but not paired")
                                    ? .green
                                    : .red
                            )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear {
                hostText = model.serverConfig.host
                portText = String(model.serverConfig.port)
                connectionMode = (model.serverConfig.preferredHost?.isEmpty == false) ? .fixed : .automatic
                discovery.start()
            }
            .onDisappear {
                discovery.stop()
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .sheet(isPresented: $showQRScanner) {
                NavigationStack {
                    ZStack(alignment: .bottom) {
                        PairingQRScannerView { raw in
                            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard let url = URL(string: trimmed) else { return }
                            showQRScanner = false
                            testing = true
                            Task {
                                let ok = await model.applyPairingURL(url)
                                await MainActor.run {
                                    testing = false
                                    if ok {
                                        hostText = model.serverConfig.host
                                        portText = String(model.serverConfig.port)
                                        secretText = ""
                                        pingResult = "Paired — connected"
                                        flashSaved()
                                    } else {
                                        pingResult = model.pairingError ?? "Pairing failed"
                                    }
                                }
                            }
                        }
                        .ignoresSafeArea()

                        Text("Aim at the QR code in UX Music → Settings on your desktop.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.bottom, 28)
                    }
                    .navigationTitle("Scan QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showQRScanner = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showDesktopPlaylistImport) {
                DesktopPlaylistImportView(isPresented: $showDesktopPlaylistImport)
                    .environment(model)
            }
        }
    }

    /// Saves host/port. If a pairing code was typed in, redeems it for a device token first; otherwise
    /// keeps whatever token is already stored (re-pairing is optional once paired).
    private func save() async {
        focusedField = nil
        selectedDiscoveryPeer = nil
        let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portText) ?? AppConstants.defaultServerPort
        let secret = secretText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !secret.isEmpty else {
            model.serverConfig = ServerConfig(
                host: host,
                port: port,
                fallbackHosts: model.serverConfig.fallbackHosts,
                token: model.serverConfig.token
            )
            flashSaved()
            return
        }

        testing = true
        let ok = await model.redeemPairing(host: host, port: port, secret: secret)
        testing = false
        if ok {
            hostText = model.serverConfig.host
            portText = String(model.serverConfig.port)
            secretText = ""
            pingResult = "Paired — connected"
            flashSaved()
        } else {
            pingResult = model.pairingError ?? "Pairing failed"
        }
    }

    private func flashSaved() {
        savedFlash = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { savedFlash = false }
        }
    }

    private func selectDiscoveredPeer(_ peer: LANDiscoveryPeer) {
        focusedField = nil
        selectedDiscoveryPeer = peer
        hostText = peer.host
        portText = String(peer.port)
        pingResult = nil
        testing = true
        let existingToken = model.serverConfig.token
        Task {
            let candidates = RemoteConnectionCandidates.hosts(manualHost: peer.host, discoveredHosts: peer.connectionHosts)
                .map { ServerConfig(host: $0, port: peer.port, token: existingToken) }
            let resolved = await RemoteConnectionResolver.resolve(candidates: candidates) { candidate in
                try await RemoteAPIClient(baseURLString: candidate.baseURLString, token: candidate.token).ping()
            }
            guard let resolved else {
                await MainActor.run {
                    testing = false
                    pingResult = "Connection failed: could not reach \(peer.displayName)"
                }
                return
            }
            let authorised = await RemoteConnectionResolver.checkAuthorised(
                client: RemoteAPIClient(baseURLString: resolved.config.baseURLString, token: existingToken)
            )
            await MainActor.run {
                testing = false
                hostText = resolved.config.host
                portText = String(resolved.config.port)
                var config = resolved.config
                config.token = existingToken
                config.fallbackHosts = candidates
                    .map(\.host)
                    .filter { $0 != resolved.config.host }
                model.serverConfig = config
                savedFlash = true
                pingResult = Self.connectionResultMessage(config: resolved.config, serverName: resolved.serverName, authorised: authorised)
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { savedFlash = false }
                }
            }
        }
    }

    private func watchActivationStatusText(_ status: WatchSessionActivationStatus) -> String {
        switch status {
        case .notActivated: return "未接続"
        case .activating: return "接続中…"
        case .activated: return "接続済み"
        case .failed(let message): return "接続失敗: \(message)"
        }
    }

    private func watchActivationStatusColor(_ status: WatchSessionActivationStatus) -> Color {
        switch status {
        case .activated: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private func watchTransferStatusText(_ phase: WatchTransferQueueItem.Phase) -> String {
        switch phase {
        case .downloading: return "ダウンロード中…"
        case .waiting: return "待機中"
        case .preparing: return "変換中…"
        case .sending: return "送信中…"
        case .sent: return "送信済み"
        case .failed(let message): return "失敗: \(message)"
        }
    }

    private func watchTransferStatusColor(_ phase: WatchTransferQueueItem.Phase) -> Color {
        switch phase {
        case .sent: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    /// Pins `knownHost` as the fixed connection target: switches `connectionMode` to `.fixed` and
    /// sets `serverConfig.preferredHost`. Tapping a row in auto mode also switches to fixed — the
    /// tap itself is the user's "use exactly this one" intent.
    private func selectKnownHost(_ knownHost: String) {
        connectionMode = .fixed
        model.serverConfig.preferredHost = knownHost
    }

    /// One row per host known from `ServerConfig.allKnownHosts` (`host` + `fallbackHosts`,
    /// deduplicated): the host string with a Tailscale/LAN badge, a reachability probe result, and
    /// a checkmark when it is the currently active host.
    private func knownHostRow(_ knownHost: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(knownHost)
                    .font(.body)
                Text(ServerConfig.isTailscaleLikeHost(knownHost) ? "Tailscale" : "LAN")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            reachabilityIndicator(for: knownHost)
            if model.serverConfig.activeHost == knownHost {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
        .task(id: knownHost) {
            await probeReachability(of: knownHost)
        }
    }

    @ViewBuilder
    private func reachabilityIndicator(for knownHost: String) -> some View {
        switch hostReachability[knownHost] {
        case .reachable:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
        case .unreachable:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.red)
        case .checking, .none:
            ProgressView()
                .controlSize(.small)
        }
    }

    /// Pings `GET /v1/identity` (unauthenticated) against `knownHost` to show a reachability
    /// verdict next to it, mirroring `RemoteConnectionResolver`'s own probe.
    private func probeReachability(of knownHost: String) async {
        hostReachability[knownHost] = .checking
        let candidate = ServerConfig(host: knownHost, port: model.serverConfig.port)
        let client = RemoteAPIClient(baseURLString: candidate.baseURLString, session: model.urlSession)
        let ok = (try? await client.ping()) != nil
        hostReachability[knownHost] = ok ? .reachable : .unreachable
    }

    private func discoveredPeerRow(_ peer: LANDiscoveryPeer) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(peer.displayName)
                    .font(.body)
                Text(peer.endpointDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !peer.protocolVersion.isEmpty {
                    Text("UX Sync \(peer.protocolVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.serverConfig == peer.serverConfig {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// If a pairing code was typed in, redeems it first (obtaining a fresh device token); otherwise
    /// checks reachability + authorisation of the currently stored token against the candidate hosts.
    private func testConnection() async {
        focusedField = nil
        testing = true
        pingResult = nil
        defer { testing = false }

        let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portText) ?? AppConstants.defaultServerPort
        let secret = secretText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !secret.isEmpty {
            let ok = await model.redeemPairing(host: host, port: port, secret: secret)
            if ok {
                hostText = model.serverConfig.host
                portText = String(model.serverConfig.port)
                secretText = ""
                pingResult = "Paired — connected"
            } else {
                pingResult = model.pairingError ?? "Pairing failed"
            }
            return
        }

        let token = model.serverConfig.token
        let candidates = connectionTestCandidates(token: token)
        let resolved = await RemoteConnectionResolver.resolve(candidates: candidates) { candidate in
            try await RemoteAPIClient(baseURLString: candidate.baseURLString, token: candidate.token).ping()
        }
        guard let resolved else {
            await MainActor.run {
                pingResult = "Connection failed: No endpoint available"
            }
            return
        }
        let authorised = await RemoteConnectionResolver.checkAuthorised(
            client: RemoteAPIClient(baseURLString: resolved.config.baseURLString, token: token)
        )
        await MainActor.run {
            hostText = resolved.config.host
            portText = String(resolved.config.port)
            var config = resolved.config
            config.token = token
            config.fallbackHosts = candidates
                .map(\.host)
                .filter { $0 != resolved.config.host }
            model.serverConfig = config
            pingResult = Self.connectionResultMessage(config: resolved.config, serverName: resolved.serverName, authorised: authorised)
        }
    }

    /// Shared by `testConnection` and `selectDiscoveredPeer`: reachable-but-unauthorised (401 on
    /// `/v1/remote/state`) must read differently from a fully connected peer, since `.pingResult`'s colour
    /// keys off whether the string starts with "Connected but not paired" (see body's `foregroundStyle`).
    private static func connectionResultMessage(config: ServerConfig, serverName: String, authorised: Bool) -> String {
        guard authorised else {
            return "Connected but not paired — scan the QR code or enter a pairing code"
        }
        return serverName.isEmpty
            ? "Connected to \(config.host)"
            : "Connected to \(serverName) via \(config.host)"
    }

    private func connectionTestCandidates(token: String) -> [ServerConfig] {
        let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portText) ?? AppConstants.defaultServerPort
        let manual = ServerConfig(host: host, port: port, token: token)
        guard let peer = selectedDiscoveryPeer, peer.port == port else {
            return [manual]
        }
        let candidateHosts = RemoteConnectionCandidates.hosts(manualHost: host, discoveredHosts: peer.connectionHosts)
        return candidateHosts.map { ServerConfig(host: $0, port: port, token: token) }
    }
}

enum RemoteConnectionCandidates {
    static func hosts(manualHost: String, discoveredHosts: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for rawHost in [manualHost] + discoveredHosts {
            let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { continue }
            let key = host.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(host)
        }
        return out
    }
}
