/// Decides how YouTube playback should respond to background and foreground transitions.
///
/// Fullscreen and PiP are the background paths because WebKit cannot resume this IFrame video
/// inline while the app is backgrounded; see background-pause.md §B-4, §C-1 and §G-1〜G-3.
struct YouTubeBackgroundResumePolicy {
    enum BackgroundDecision: Equatable {
        case noAction
        case keepPlaying
        case pauseAndResume
    }

    struct ForegroundDecision: Equatable {
        let exitPictureInPicture: Bool
        let resumePlayback: Bool
    }

    enum RemotePlayDecision: Equatable {
        case deferUntilForeground
        case playNow
    }

    static func onEnterBackground(
        isYouTubeSong: Bool,
        isPlaying: Bool,
        presentationMode: YouTubeEmbedPlayer.PresentationMode
    ) -> BackgroundDecision {
        guard isYouTubeSong, isPlaying else {
            return .noAction
        }
        switch presentationMode {
        case .fullscreen, .pictureInPicture:
            return .keepPlaying
        case .inline, .unknown:
            return .pauseAndResume
        }
    }

    static func onEnterForeground(
        resumePending: Bool,
        isYouTubeSong: Bool,
        presentationMode: YouTubeEmbedPlayer.PresentationMode
    ) -> ForegroundDecision {
        ForegroundDecision(
            exitPictureInPicture: isYouTubeSong && presentationMode == .pictureInPicture,
            resumePlayback: resumePending && isYouTubeSong
        )
    }

    static func onRemotePlayWhileBackgrounded(
        isYouTubeSong: Bool,
        isPictureInPictureActive: Bool
    ) -> RemotePlayDecision {
        isYouTubeSong && !isPictureInPictureActive ? .deferUntilForeground : .playNow
    }
}
