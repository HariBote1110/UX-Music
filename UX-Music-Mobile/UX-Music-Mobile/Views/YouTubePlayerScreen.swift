import SwiftUI

/// Resolves `song`'s YouTube URL (`song.sourceURL`, falling back to `song.path`) to video metadata
/// and presents the full-screen official embed player. Used when a YouTube library entry is tapped
/// in `RemoteLibraryScreen` — the dedicated "YouTube" tab was removed in favour of YouTube songs
/// living in the normal library alongside local files (see `Song.sourceType`).
struct RemoteYouTubeSongPlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    let song: Song

    @State private var resolvedVideo: RemoteYouTubeVideoInfo?
    @State private var resolveError: String?

    private var client: RemoteAPIClient {
        RemoteAPIClient(baseURLString: appModel.serverConfig.baseURLString, token: appModel.serverConfig.token)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let video = resolvedVideo {
                YouTubeFullScreenPlayer(video: video)
            } else if let resolveError {
                VStack(spacing: 12) {
                    Text(resolveError)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("閉じる") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            appModel.player.stop()
            let url = song.sourceURL ?? song.path
            do {
                resolvedVideo = try await client.resolveYouTubeVideo(url: url)
            } catch {
                resolveError = "動画情報を取得できませんでした。デスクトップとのペアリング状態を確認してください。"
            }
        }
    }
}

/// Full-screen official embed player (WKWebView), styled to match `NowPlayingView`'s black backdrop.
struct YouTubeFullScreenPlayer: View {
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
