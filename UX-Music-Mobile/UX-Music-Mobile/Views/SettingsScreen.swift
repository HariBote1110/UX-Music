import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var hostText = ""
    @State private var portText = ""
    @State private var pingResult: String?
    @State private var testing = false
    @State private var savedFlash = false
    @State private var showQRScanner = false
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
        }
    }

    private func save() {
        focusedField = nil
        let port = Int(portText) ?? AppConstants.defaultServerPort
        model.serverConfig = ServerConfig(host: hostText.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
        savedFlash = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { savedFlash = false }
        }
    }

    private func testConnection() async {
        focusedField = nil
        testing = true
        pingResult = nil
        defer { testing = false }
        do {
            let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = Int(portText) ?? AppConstants.defaultServerPort
            let client = WearAPIClient(baseURLString: ServerConfig(host: host, port: port).baseURLString)
            let name = try await client.ping()
            await MainActor.run {
                pingResult = name.isEmpty ? "Connected" : "Connected to \(name)"
            }
        } catch {
            await MainActor.run {
                pingResult = "Connection failed: \(error.localizedDescription)"
            }
        }
    }
}
