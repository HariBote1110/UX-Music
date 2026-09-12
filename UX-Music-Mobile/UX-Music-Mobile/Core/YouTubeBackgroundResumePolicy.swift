/// Decides how YouTube playback should respond to background and foreground transitions.
///
/// PiP is the primary background path because WebKit cannot resume this IFrame video inline while
/// the app is backgrounded; see `mobile_youtube_background_research/notes/background-pause.md`.
struct YouTubeBackgroundResumePolicy {
    enum PictureInPictureRequest: Equatable {
        case notRequested
        case entered
        case failed
    }

    enum BackgroundDecision: Equatable {
        case noAction
        case keepPlaying
        case requestPictureInPicture
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
        isPictureInPictureActive: Bool,
        canUsePictureInPicture: Bool,
        pictureInPictureRequest: PictureInPictureRequest = .notRequested
    ) -> BackgroundDecision {
        guard isYouTubeSong, isPlaying else {
            return .noAction
        }
        if isPictureInPictureActive {
            return .keepPlaying
        }
        if pictureInPictureRequest == .entered {
            return .keepPlaying
        }
        if canUsePictureInPicture {
            switch pictureInPictureRequest {
            case .notRequested:
                return .requestPictureInPicture
            case .entered:
                return .keepPlaying
            case .failed:
                return .pauseAndResume
            }
        }
        return .pauseAndResume
    }

    static func onEnterForeground(
        resumePending: Bool,
        isYouTubeSong: Bool,
        isPictureInPictureActive: Bool
    ) -> ForegroundDecision {
        ForegroundDecision(
            exitPictureInPicture: isYouTubeSong && isPictureInPictureActive,
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
