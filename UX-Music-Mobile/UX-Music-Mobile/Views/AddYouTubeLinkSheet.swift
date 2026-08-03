import SwiftUI

/// Sheet for adding a YouTube video to the desktop's library, reached from the Remote library's
/// ellipsis menu. Replaces the previous dedicated "YouTube" tab: the desktop has no on-device
/// YouTube search, only URL-based lookup (`AddYouTubeLink` in `server/app_youtube.go`), so this
/// mirrors that "paste a link" flow. On success the song appears in the Remote library like any
/// other song (see `Song.sourceType`), so this sheet just refreshes the library and closes.
struct AddYouTubeLinkSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    @State private var urlText: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var client: RemoteAPIClient {
        RemoteAPIClient(baseURLString: model.serverConfig.baseURLString, token: model.serverConfig.token)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("YouTubeのURLを貼り付け", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else {
                        Text("デスクトップの再生モード設定に従い、ライブラリへ楽曲として追加されます。")
                    }
                }
            }
            .navigationTitle("YouTube の URL を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("追加") { Task { await submit() } }
                            .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func submit() async {
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await client.addYouTubeLink(url: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
            await model.refreshLibrary()
            isPresented = false
        } catch {
            errorMessage = "追加できませんでした。URLとペアリング状態を確認してください。"
        }
    }
}
