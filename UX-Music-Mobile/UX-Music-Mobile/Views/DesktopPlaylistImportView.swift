import SwiftUI

/// Sheet: fetch desktop playlists, choose how to handle tracks not stored on device, then import.
struct DesktopPlaylistImportView: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    @State private var rows: [RemoteDesktopPlaylist] = []
    @State private var isLoadingPreview = true
    @State private var previewError: String?
    @State private var missingPolicy: DesktopPlaylistMissingPolicy = .omitMissingDownloads
    @State private var isImporting = false
    @State private var importError: String?
    @State private var outcome: DesktopPlaylistImportOutcome?
    @State private var showOutcomeAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoadingPreview {
                    ProgressView("Loading from Desktop…")
                        .tint(.white)
                        .foregroundStyle(.secondary)
                } else if let previewError {
                    Text(previewError)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    importForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("Desktop Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        isPresented = false
                    }
                    .disabled(isImporting)
                }
            }
            .task {
                await loadPreview()
            }
            .alert("Import Result", isPresented: $showOutcomeAlert) {
                Button("OK") {
                    isPresented = false
                }
            } message: {
                Text(outcomeSummary)
            }
            .alert("Import Error", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    @ViewBuilder
    private var importForm: some View {
        let strayPaths = rows.reduce(0) { $0 + ($1.pathsNotInLibrary?.count ?? 0) }
        let missingSongIds = Set(rows.flatMap(\.songIds).filter { !model.isSongDownloaded(songId: $0) })

        Form {
            Section {
                LabeledContent("Playlist Count", value: "\(rows.count)")
                LabeledContent("Unresolved Paths on Desktop", value: "\(strayPaths)")
                LabeledContent("Songs Not Saved on Device", value: "\(missingSongIds.count)")
            } header: {
                Text("Overview")
            }

            Section {
                Picker("Handling of Unsaved Songs", selection: $missingPolicy) {
                    Text("Omit from Playlist").tag(DesktopPlaylistMissingPolicy.omitMissingDownloads)
                    Text("Download First").tag(DesktopPlaylistMissingPolicy.downloadMissingTracks)
                }
                .pickerStyle(.inline)
            } header: {
                Text("Import Method")
            } footer: {
                Text("\"Omit\" adds only the songs already on this device, in order. \"Download\" fetches the missing ones from the desktop first, in the same order, then adds them (songs that fail to download are skipped).")
            }

            Section {
                Button {
                    Task { await runImport() }
                } label: {
                    if isImporting {
                        HStack {
                            ProgressView()
                            Text("Importing…")
                        }
                    } else {
                        Text("Import with These Settings")
                    }
                }
                .disabled(isImporting || rows.isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }

    private var outcomeSummary: String {
        guard let outcome else { return "" }
        var parts: [String] = [
            String(format: String(localized: "Playlists created: %ld"), outcome.playlistsCreated),
            String(format: String(localized: "Skipped (empty): %ld"), outcome.playlistsSkippedEmpty),
            String(format: String(localized: "Paths outside desktop library: %ld"), outcome.desktopPathsMissingFromLibrary),
            String(format: String(localized: "Songs not included on device: %ld"), outcome.tracksOmittedNotDownloaded),
            String(format: String(localized: "Failed downloads: %ld"), outcome.failedTrackDownloads)
        ]
        return parts.joined(separator: "\n")
    }

    private func loadPreview() async {
        isLoadingPreview = true
        previewError = nil
        defer { isLoadingPreview = false }
        do {
            rows = try await model.fetchDesktopPlaylistsPreview()
        } catch {
            previewError = error.localizedDescription
        }
    }

    private func runImport() async {
        importError = nil
        isImporting = true
        defer { isImporting = false }
        do {
            let o = try await model.importDesktopPlaylists(missingPolicy: missingPolicy)
            outcome = o
            showOutcomeAlert = true
        } catch {
            importError = error.localizedDescription
        }
    }
}
