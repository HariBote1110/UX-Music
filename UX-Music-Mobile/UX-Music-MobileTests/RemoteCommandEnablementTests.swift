import XCTest
@testable import UX_Music_Mobile

final class RemoteCommandEnablementTests: XCTestCase {
    func testNoSongDisablesEverythingExceptToggleStillFollowsHasSong() {
        let state = RemoteCommandEnablement.state(hasSong: false, isPlaying: false)
        XCTAssertFalse(state.playEnabled)
        XCTAssertFalse(state.pauseEnabled)
        XCTAssertFalse(state.toggleEnabled)
    }

    func testSongPlayingEnablesPauseOnlyNotPlay() {
        let state = RemoteCommandEnablement.state(hasSong: true, isPlaying: true)
        XCTAssertFalse(state.playEnabled)
        XCTAssertTrue(state.pauseEnabled)
        XCTAssertTrue(state.toggleEnabled)
    }

    func testSongPausedEnablesPlayOnlyNotPause() {
        let state = RemoteCommandEnablement.state(hasSong: true, isPlaying: false)
        XCTAssertTrue(state.playEnabled)
        XCTAssertFalse(state.pauseEnabled)
        XCTAssertTrue(state.toggleEnabled)
    }

    func testPlayAndPauseAreNeverBothEnabled() {
        for hasSong in [true, false] {
            for isPlaying in [true, false] {
                let state = RemoteCommandEnablement.state(hasSong: hasSong, isPlaying: isPlaying)
                XCTAssertFalse(state.playEnabled && state.pauseEnabled)
            }
        }
    }
}
