import XCTest
@testable import UX_Music_Mobile

final class YouTubeBackgroundResumePolicyTests: XCTestCase {
    func testPlayingYouTubeSongKeepsPlayingInFullscreen() {
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: true,
            isPlaying: true,
            presentationMode: .fullscreen
        )

        XCTAssertEqual(decision, .keepPlaying)
    }

    func testPlayingYouTubeSongKeepsPlayingWhenPictureInPictureIsAlreadyActive() {
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: true,
            isPlaying: true,
            presentationMode: .pictureInPicture
        )

        XCTAssertEqual(decision, .keepPlaying)
    }

    func testInlineYouTubePlaybackUsesThePauseAndResumeFallback() {
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: true,
            isPlaying: true,
            presentationMode: .inline
        )

        XCTAssertEqual(decision, .pauseAndResume)
    }

    func testUnknownPresentationModeUsesThePauseAndResumeFallback() {
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: true,
            isPlaying: true,
            presentationMode: .unknown
        )

        XCTAssertEqual(decision, .pauseAndResume)
    }

    func testBackgroundEntryDoesNothingForPausedOrNonYouTubePlayback() {
        let cases = [
            (isYouTubeSong: true, isPlaying: false),
            (isYouTubeSong: false, isPlaying: true),
            (isYouTubeSong: false, isPlaying: false)
        ]

        for input in cases {
            let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
                isYouTubeSong: input.isYouTubeSong,
                isPlaying: input.isPlaying,
                presentationMode: .inline
            )

            XCTAssertEqual(decision, .noAction)
        }
    }

    func testForegroundExitsPictureInPictureAndKeepsPendingResumeDecisionIndependent() {
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: true,
                isYouTubeSong: true,
                isPlaying: false,
                presentationMode: .pictureInPicture
            ),
            YouTubeBackgroundResumePolicy.ForegroundDecision(
                exitPictureInPicture: true,
                resumePlayback: true,
                resumeAfterPictureInPictureExit: false
            )
        )
    }

    func testForegroundResumesPlayingPictureInPictureAfterItExits() {
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: false,
                isYouTubeSong: true,
                isPlaying: true,
                presentationMode: .pictureInPicture
            ),
            YouTubeBackgroundResumePolicy.ForegroundDecision(
                exitPictureInPicture: true,
                resumePlayback: false,
                resumeAfterPictureInPictureExit: true
            )
        )
    }

    func testForegroundDoesNotResumePausedPictureInPicture() {
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: false,
                isYouTubeSong: true,
                isPlaying: false,
                presentationMode: .pictureInPicture
            ),
            YouTubeBackgroundResumePolicy.ForegroundDecision(
                exitPictureInPicture: true,
                resumePlayback: false,
                resumeAfterPictureInPictureExit: false
            )
        )
    }

    func testForegroundDoesNotForceExitFullscreen() {
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: false,
                isYouTubeSong: true,
                isPlaying: false,
                presentationMode: .fullscreen
            ),
            YouTubeBackgroundResumePolicy.ForegroundDecision(
                exitPictureInPicture: false,
                resumePlayback: false,
                resumeAfterPictureInPictureExit: false
            )
        )
    }

    func testForegroundOnlyResumesPendingFallbackPlayback() {
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: true,
                isYouTubeSong: true,
                isPlaying: false,
                presentationMode: .inline
            ),
            YouTubeBackgroundResumePolicy.ForegroundDecision(
                exitPictureInPicture: false,
                resumePlayback: true,
                resumeAfterPictureInPictureExit: false
            )
        )
    }

    func testRemotePlayActsImmediatelyWhenPictureInPictureIsActive() {
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onRemotePlayWhileBackgrounded(
                isYouTubeSong: true,
                isPictureInPictureActive: true
            ),
            .playNow
        )
    }

    func testRemotePlayDefersYouTubePlaybackUntilForegroundWithoutPictureInPicture() {
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onRemotePlayWhileBackgrounded(
                isYouTubeSong: true,
                isPictureInPictureActive: false
            ),
            .deferUntilForeground
        )
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onRemotePlayWhileBackgrounded(
                isYouTubeSong: false,
                isPictureInPictureActive: false
            ),
            .playNow
        )
    }
}
