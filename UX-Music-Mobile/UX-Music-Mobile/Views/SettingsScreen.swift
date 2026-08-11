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
    /// Whether the most recent `pingResult` represents a successful (green) or failed (red)
    /// outcome. Kept as a separate flag rather than inspecting `pingResult`'s text — the text is
    /// localised for display, so string-prefix matching on it (the previous approach) would break
    /// once the message is translated to a non-English locale.
    @State private var pingIsHealthy = false
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
                        Text("Connected host")
                        Spacer()
                        Text(verbatim: "\(model.serverConfig.activeHost) (\(connectionMode == .fixed ? String(localized: "Fixed") : String(localized: "Automatic")))")
                            .foregroundStyle(.secondary)
                    }

                    Picker("Connection mode", selection: $connectionMode) {
                        Text("Automatic (Recommended)").tag(ConnectionSelectionMode.automatic)
                        Text("Fixed").tag(ConnectionSelectionMode.fixed)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: connectionMode) { _, newMode in
                        if newMode == .automatic {
                            model.serverConfig.preferredHost = nil
                        }
                    }

                    if model.serverConfig.allKnownHosts.isEmpty {
                        Text("No known hosts yet. Candidates appear once you connect via pairing or Discovery.")
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
                    Text("Connection Target")
                } footer: {
                    Text(connectionMode == .fixed
                        ? "In fixed mode, only the selected host is used — there is no automatic fallback to other candidates on failure."
                        : "In automatic mode, hosts are tried from the top until one responds, and the successful host is remembered as the preferred target.")
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

                    TextField("Pairing Code (secret)", text: $secretText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .secret)
                } header: {
                    Text("SERVER")
                } footer: {
                    Text("The code shown in the desktop UX Music app's Settings → Pairing QR. Scanning the QR code fills this in and exchanges it automatically. If typed manually, tap Save or Test to exchange it for a device token.")
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
                        Text("Connection Status")
                        Spacer()
                        Text(watchActivationStatusText(model.watchTransferBridge.activationStatus))
                            .foregroundStyle(watchActivationStatusColor(model.watchTransferBridge.activationStatus))
                    }
                    HStack {
                        Text("Pairing Status")
                        Spacer()
                        Text(model.watchTransferBridge.isPaired ? "Paired" : "Not Paired")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Watch App")
                        Spacer()
                        Text(model.watchTransferBridge.isWatchAppInstalled ? "Installed" : "Not Installed")
                            .foregroundStyle(.secondary)
                    }
                    if model.watchTransferBridge.queue.isEmpty {
                        Text("No transferred songs yet. Long-press a song in your local library and choose \u{201C}Transfer to Apple Watch\u{201D}.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        let summary = WatchTransferQueueSummary.aggregate(items: model.watchTransferBridge.queue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(format: String(localized: "Completed %lld of %lld"), summary.completedCount, summary.totalCount))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if summary.isActive {
                                ProgressView(value: summary.meanFraction)
                            }
                        }
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
                    Picker("Download Quality", selection: Bindable(model).downloadAudioQuality) {
                        ForEach(DownloadAudioQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("AAC Bitrate", selection: Bindable(model).downloadAACBitrate) {
                        ForEach(DownloadAACBitrate.allCases) { bitrate in
                            Text(bitrate.displayName).tag(bitrate)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.downloadAudioQuality == .original)
                } header: {
                    Text("Download")
                } footer: {
                    Text("AAC is about 1/7 the size, so transfers to Apple Watch are faster. With \u{201C}Full + AAC\u{201D}, playback uses full quality while Watch transfers use AAC. This does not apply retroactively to songs already downloaded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Higher bitrates sound better but take up more space. Apple Watch transfers always optimise to 128 kbps regardless of this setting.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Import Desktop Playlists") {
                        showDesktopPlaylistImport = true
                    }
                    .disabled(!model.serverConfig.isConfigured)
                    if !model.serverConfig.isConfigured {
                        Text("Enter and save a host name to copy desktop playlists to this device.")
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
                            .foregroundStyle(pingIsHealthy ? .green : .red)
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
                                        pingResult = String(localized: "Paired — connected")
                                        pingIsHealthy = true
                                        flashSaved()
                                    } else {
                                        pingResult = model.pairingError ?? String(localized: "Pairing failed")
                                        pingIsHealthy = false
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
            pingResult = String(localized: "Paired — connected")
            pingIsHealthy = true
            flashSaved()
        } else {
            pingResult = model.pairingError ?? String(localized: "Pairing failed")
            pingIsHealthy = false
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
                    pingResult = String(format: String(localized: "Connection failed: could not reach %@"), peer.displayName)
                    pingIsHealthy = false
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
                pingIsHealthy = authorised
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { savedFlash = false }
                }
            }
        }
    }

    private func watchActivationStatusText(_ status: WatchSessionActivationStatus) -> String {
        switch status {
        case .notActivated: return String(localized: "Not Connected")
        case .activating: return String(localized: "Connecting…")
        case .activated: return String(localized: "Connected")
        case .failed(let message):
            return String(format: String(localized: "Connection failed: %@"), message)
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
        case .downloading: return String(localized: "Downloading…")
        case .waiting: return String(localized: "Waiting")
        case .preparing: return String(localized: "Converting…")
        case .sending(let fraction):
            return String(format: String(localized: "Sending… %d%%"), Int((fraction * 100).rounded()))
        case .sent: return String(localized: "Sent")
        case .failed(let message):
            return String(format: String(localized: "Failed: %@"), message)
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
                    Text(verbatim: "UX Sync \(peer.protocolVersion)")
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
                pingResult = String(localized: "Paired — connected")
                pingIsHealthy = true
            } else {
                pingResult = model.pairingError ?? String(localized: "Pairing failed")
                pingIsHealthy = false
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
                pingResult = String(localized: "Connection failed: No endpoint available")
                pingIsHealthy = false
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
            pingIsHealthy = authorised
        }
    }

    /// Shared by `testConnection` and `selectDiscoveredPeer`. `authorised` (not the returned text)
    /// drives `pingIsHealthy`, since the text is localised for display and must not be pattern
    /// matched.
    private static func connectionResultMessage(config: ServerConfig, serverName: String, authorised: Bool) -> String {
        guard authorised else {
            return String(localized: "Connected but not paired — scan the QR code or enter a pairing code")
        }
        return serverName.isEmpty
            ? String(format: String(localized: "Connected to %@"), config.host)
            : String(format: String(localized: "Connected to %@ via %@"), serverName, config.host)
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
