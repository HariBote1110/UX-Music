import XCTest
@testable import UX_Music_Mobile

final class YouTubeBackgroundResumePolicyTests: XCTestCase {
    func testPlayingYouTubeSongPausesAndResumesOnForeground() {
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: true,
            isPlaying: true
        )

        XCTAssertTrue(decision.pauseNow)
        XCTAssertTrue(decision.resumeOnForeground)
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
                isPlaying: input.isPlaying
            )

            XCTAssertFalse(decision.pauseNow)
            XCTAssertFalse(decision.resumeOnForeground)
        }
    }

    func testForegroundOnlyResumesPendingYouTubePlayback() {
        XCTAssertTrue(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: true,
                isYouTubeSong: true
            )
        )
        XCTAssertFalse(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: false,
                isYouTubeSong: true
            )
        )
        XCTAssertFalse(
            YouTubeBackgroundResumePolicy.onEnterForeground(
                resumePending: true,
                isYouTubeSong: false
            )
        )
    }

    func testRemotePlayDefersYouTubePlaybackUntilForeground() {
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onRemotePlayWhileBackgrounded(isYouTubeSong: true),
            .deferUntilForeground
        )
        XCTAssertEqual(
            YouTubeBackgroundResumePolicy.onRemotePlayWhileBackgrounded(isYouTubeSong: false),
            .playNow
        )
    }
}
