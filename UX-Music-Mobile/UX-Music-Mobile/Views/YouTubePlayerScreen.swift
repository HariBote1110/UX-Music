import SwiftUI

/// YouTube official playback screen (phase 1: foreground-only).
///
/// The desktop app has no on-device search — only "paste a YouTube URL" — so this screen
/// mirrors that: a link field resolves video metadata via `RemoteAPIClient.resolveYouTubeVideo`,
/// then opens the full-screen WKWebView embed player. Starting YouTube playback pauses any local
/// `MusicPlayerService` playback so the two never overlap.
struct YouTubePlayerScreen: View {
    @Environment(AppModel.self) private var appModel

    @State private var urlText: String = ""
    @State private var isResolving = false
    @State private var resolveError: String?
    @State private var resolvedVideo: RemoteYouTubeVideoInfo?
    @State private var isPlayerPresented = false

    private var client: RemoteAPIClient {
        RemoteAPIClient(baseURLString: appModel.serverConfig.baseURLString, token: appModel.serverConfig.token)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("YouTubeのURLを貼り付け", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        Task { await resolve() }
                    } label: {
                        if isResolving {
                            ProgressView()
                        } else {
                            Text("動画情報を取得")
                        }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving)
                } footer: {
                    if let resolveError {
                        Text(resolveError).foregroundStyle(.red)
                    } else {
                        Text("デスクトップとペアリング済みのYouTube URLを貼り付けると、公式プレイヤーで再生できます。")
                    }
                }

                if let video = resolvedVideo {
                    Section {
                        Button {
                            appModel.player.stop()
                            isPlayerPresented = true
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(video.title).font(.headline).lineLimit(2)
                                    Text(video.author).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill").font(.title2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("YouTube")
            .fullScreenCover(isPresented: $isPlayerPresented) {
                if let video = resolvedVideo {
                    YouTubeFullScreenPlayer(video: video)
                }
            }
        }
    }

    private func resolve() async {
        resolveError = nil
        resolvedVideo = nil
        isResolving = true
        defer { isResolving = false }
        do {
            resolvedVideo = try await client.resolveYouTubeVideo(url: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            resolveError = "動画情報を取得できませんでした。URLとペアリング状態を確認してください。"
        }
    }
}

/// Full-screen official embed player (WKWebView), styled to match `NowPlayingView`'s black backdrop.
private struct YouTubeFullScreenPlayer: View {
    let video: RemoteYouTubeVideoInfo

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = YouTubePlayerController()
    @State private var isPlaying = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                YouTubeEmbedPlayerView(videoID: video.videoId, controller: controller) { event in
                    switch event {
                    case .state(.playing):
                        isPlaying = true
                    case .state(.paused), .state(.ended):
                        isPlaying = false
                    default:
                        break
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)

                Text(video.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.top, 16)
                    .padding(.horizontal)
                Text(video.author)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal)

                Spacer()

                Button {
                    controller.send(isPlaying ? .pause : .play)
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 40)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.85))
                }
                .padding()
            }
        }
    }
}
