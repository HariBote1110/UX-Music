import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var hostText = ""
    @State private var portText = ""
    @State private var pingResult: String?
    @State private var testing = false
    @State private var savedFlash = false
    @State private var showQRScanner = false
    @State private var showDesktopPlaylistImport = false
    @State private var selectedDiscoveryPeer: WearDiscoveryPeer?
    @StateObject private var discovery = WearDiscoveryService()
    @FocusState private var focusedField: Field?

    private enum Field {
        case host, port
    }

    var body: some View {
        NavigationStack {
            List {
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
                } header: {
                    Text("SERVER")
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
                            save()
                        }
                        .buttonStyle(.borderedProminent)

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
                            .foregroundStyle(pingResult.hasPrefix("Connected") ? .green : .red)
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
                            guard let url = URL(string: trimmed), model.applyPairingURL(url) else { return }
                            hostText = model.serverConfig.host
                            portText = String(model.serverConfig.port)
                            pingResult = "Paired — tap Test to verify"
                            showQRScanner = false
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

    private func save() {
        focusedField = nil
        selectedDiscoveryPeer = nil
        let port = Int(portText) ?? AppConstants.defaultServerPort
        model.serverConfig = ServerConfig(host: hostText.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
        savedFlash = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { savedFlash = false }
        }
    }

    private func selectDiscoveredPeer(_ peer: WearDiscoveryPeer) {
        focusedField = nil
        selectedDiscoveryPeer = peer
        hostText = peer.host
        portText = String(peer.port)
        model.serverConfig = peer.serverConfig
        savedFlash = true
        pingResult = "Selected \(peer.displayName)"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { savedFlash = false }
        }
    }

    private func discoveredPeerRow(_ peer: WearDiscoveryPeer) -> some View {
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

    private func testConnection() async {
        focusedField = nil
        testing = true
        pingResult = nil
        defer { testing = false }
        let candidates = connectionTestCandidates()
        var failures: [String] = []
        for candidate in candidates {
            do {
                let client = WearAPIClient(baseURLString: candidate.baseURLString)
                let name = try await client.ping()
                await MainActor.run {
                    hostText = candidate.host
                    portText = String(candidate.port)
                    model.serverConfig = candidate
                    pingResult = name.isEmpty
                        ? "Connected to \(candidate.host)"
                        : "Connected to \(name) via \(candidate.host)"
                }
                return
            } catch {
                failures.append("\(candidate.host): \(error.localizedDescription)")
            }
        }

        await MainActor.run {
            pingResult = "Connection failed: \(failures.first ?? "No endpoint available")"
        }
    }

    private func connectionTestCandidates() -> [ServerConfig] {
        let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(portText) ?? AppConstants.defaultServerPort
        let manual = ServerConfig(host: host, port: port)
        guard let peer = selectedDiscoveryPeer, peer.port == port else {
            return [manual]
        }
        let candidateHosts = WearConnectionCandidates.hosts(manualHost: host, discoveredHosts: peer.connectionHosts)
        return candidateHosts.map { ServerConfig(host: $0, port: port) }
    }
}

enum WearConnectionCandidates {
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
