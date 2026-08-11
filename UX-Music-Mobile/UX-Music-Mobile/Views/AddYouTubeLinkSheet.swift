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
                    TextField("Paste YouTube URL", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else {
                        Text("Songs are added to the library according to the desktop's playback mode setting.")
                    }
                }
            }
            .navigationTitle("Add YouTube URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Button("Add") { Task { await submit() } }
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
            errorMessage = String(localized: "Couldn't add it. Check the URL and pairing status.")
        }
    }
}
