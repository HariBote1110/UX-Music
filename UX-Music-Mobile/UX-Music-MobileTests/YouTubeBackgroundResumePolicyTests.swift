import XCTest
@testable import UX_Music_Mobile

final class YouTubeBackgroundResumePolicyTests: XCTestCase {
    func testPlayingYouTubeSongRequestsPictureInPictureWhenAvailable() {
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: true,
            isPlaying: true,
            isPictureInPictureActive: false,
            canUsePictureInPicture: true
        )

        XCTAssertEqual(decision, .requestPictureInPicture)
    }

    func testPlayingYouTubeSongKeepsPlayingWhenPictureInPictureIsAlreadyActive() {
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: true,
            isPlaying: true,
            isPictureInPictureActive: true,
            canUsePictureInPicture: true
        )

        XCTAssertEqual(decision, .keepPlaying)
    }

    func testPictureInPictureFailureUsesThePauseAndResumeFallback() {
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: true,
            isPlaying: true,
            isPictureInPictureActive: false,
            canUsePictureInPicture: true,
            pictureInPictureRequest: .failed
        )

        XCTAssertEqual(decision, .pauseAndResume)
    }

    func testSuccessfulPictureInPictureRequestKeepsPlaying() {
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: true,
            isPlaying: true,
            isPictureInPictureActive: false,
            canUsePictureInPicture: true,
            pictureInPictureRequest: .entered
        )

        XCTAssertEqual(decision, .keepPlaying)
    }

    func testUnavailablePictureInPictureUsesThePauseAndResumeFallback() {
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: true,
            isPlaying: true,
            isPictureInPictureActive: false,
            canUsePictureInPicture: false
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
                isPictureInPictureActive: false,
                canUsePictureInPicture: true
            )

            XCTAssertEqual(decision, .noAction)
        }
    }

    func testForegroundExitsPictureInPictureAndKeepsPendingResumeDecisionIndependent() {
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: true,
                isYouTubeSong: true,
                isPictureInPictureActive: true
            ),
            YouTubeBackgroundResumePolicy.ForegroundDecision(
                exitPictureInPicture: true,
                resumePlayback: true
            )
        )
    }

    func testForegroundOnlyResumesPendingFallbackPlayback() {
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: false,
                isYouTubeSong: true,
                isPictureInPictureActive: false
            ),
            YouTubeBackgroundResumePolicy.ForegroundDecision(
                exitPictureInPicture: false,
                resumePlayback: false
            )
        )
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: true,
                isYouTubeSong: true,
                isPictureInPictureActive: false
            ),
            YouTubeBackgroundResumePolicy.ForegroundDecision(
                exitPictureInPicture: false,
                resumePlayback: true
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
