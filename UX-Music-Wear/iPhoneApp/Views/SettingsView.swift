import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var settings = WearSettings.load()
    @State private var pingResult: String?
    @State private var pinging = false

    var body: some View {
        NavigationStack {
            Form {
                Section("UX Music Server") {
                    HStack {
                        Text("Host")
                        Spacer()
                        TextField("192.168.x.x", text: $settings.serverHost)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("8765", value: $settings.serverPort, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    Button(pinging ? "Checking…" : "Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(pinging || settings.serverHost.isEmpty)

                    if let pingResult {
                        Text(pingResult)
                            .font(.caption)
                            .foregroundStyle(pingResult.hasPrefix("✓") ? .green : .red)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "0.1.0-Alpha-1a")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        settings.save()
                        store.configure(with: settings)
                        Task { await store.refresh() }
                    }
                }
            }
            .onAppear { settings = WearSettings.load() }
        }
    }

    private func testConnection() async {
        guard let url = settings.baseURL else { return }
        pinging = true
        pingResult = nil
        let client = MusicServerClient(baseURL: url)
        do {
            let pong = try await client.ping()
            pingResult = "✓ Connected to \(pong.hostname) (v\(pong.version))"
        } catch {
            pingResult = "✗ \(error.localizedDescription)"
        }
        pinging = false
    }
}
