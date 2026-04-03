import SwiftUI

/// Sheet: fetch desktop playlists, choose how to handle tracks not stored on device, then import.
struct DesktopPlaylistImportView: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    @State private var rows: [WearDesktopPlaylist] = []
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
                    ProgressView("デスクトップから読み込み中…")
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
            .navigationTitle("デスクトップのプレイリスト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        isPresented = false
                    }
                    .disabled(isImporting)
                }
            }
            .task {
                await loadPreview()
            }
            .alert("取り込み結果", isPresented: $showOutcomeAlert) {
                Button("OK") {
                    isPresented = false
                }
            } message: {
                Text(outcomeSummary)
            }
            .alert("取り込みエラー", isPresented: Binding(
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
                LabeledContent("プレイリスト数", value: "\(rows.count)")
                LabeledContent("デスクトップ側で未解決のパス", value: "\(strayPaths)")
                LabeledContent("端末に未保存の曲", value: "\(missingSongIds.count)")
            } header: {
                Text("概要")
            }

            Section {
                Picker("未保存の曲の扱い", selection: $missingPolicy) {
                    Text("プレイリストから除いて取り込む").tag(DesktopPlaylistMissingPolicy.omitMissingDownloads)
                    Text("先にダウンロードしてから取り込む").tag(DesktopPlaylistMissingPolicy.downloadMissingTracks)
                }
                .pickerStyle(.inline)
            } header: {
                Text("取り込み方法")
            } footer: {
                Text("「除く」は端末にある曲だけを並び順どおりに追加します。「ダウンロード」は不足分をデスクトップから順に取得してから同じ順で追加します（取得に失敗した曲はスキップされます）。")
            }

            Section {
                Button {
                    Task { await runImport() }
                } label: {
                    if isImporting {
                        HStack {
                            ProgressView()
                            Text("取り込み中…")
                        }
                    } else {
                        Text("この内容で取り込む")
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
            "作成したプレイリスト: \(outcome.playlistsCreated) 件",
            "空のためスキップ: \(outcome.playlistsSkippedEmpty) 件",
            "デスクトップライブラリ外のパス: \(outcome.desktopPathsMissingFromLibrary) 件",
            "端末に含めなかった曲: \(outcome.tracksOmittedNotDownloaded) 件",
            "ダウンロード失敗: \(outcome.failedTrackDownloads) 件"
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
