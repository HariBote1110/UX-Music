/// Decides how YouTube playback should respond to background and foreground transitions.
///
/// WebKit cannot resume this IFrame video while the app is backgrounded; see
/// `mobile_youtube_background_research/notes/background-pause.md`.
struct YouTubeBackgroundResumePolicy {
    enum RemotePlayDecision: Equatable {
        case deferUntilForeground
        case playNow
    }

    static func onEnterBackground(
        isYouTubeSong: Bool,
        isPlaying: Bool
    ) -> (pauseNow: Bool, resumeOnForeground: Bool) {
        guard isYouTubeSong, isPlaying else {
            return (pauseNow: false, resumeOnForeground: false)
        }
        return (pauseNow: true, resumeOnForeground: true)
    }

    static func onEnterForeground(resumePending: Bool, isYouTubeSong: Bool) -> Bool {
        resumePending && isYouTubeSong
    }

    static func onRemotePlayWhileBackgrounded(isYouTubeSong: Bool) -> RemotePlayDecision {
        isYouTubeSong ? .deferUntilForeground : .playNow
    }
}
