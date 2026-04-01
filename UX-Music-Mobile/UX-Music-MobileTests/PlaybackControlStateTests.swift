import AVFoundation
import XCTest
@testable import UX_Music_Mobile

final class PlaybackControlStateTests: XCTestCase {
    func testWaitingToPlayAtSpecifiedRateShowsPauseDespiteZeroRate() {
        XCTAssertTrue(
            PlaybackControlState.showsPauseButton(timeControlStatus: .waitingToPlayAtSpecifiedRate, rate: 0)
        )
    }

    func testPlayingShowsPause() {
        XCTAssertTrue(PlaybackControlState.showsPauseButton(timeControlStatus: .playing, rate: 1))
    }

    func testPausedWithZeroRateShowsPlay() {
        XCTAssertFalse(PlaybackControlState.showsPauseButton(timeControlStatus: .paused, rate: 0))
    }
}
