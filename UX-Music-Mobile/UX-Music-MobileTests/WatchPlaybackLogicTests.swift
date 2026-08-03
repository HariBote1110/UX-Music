import MediaPlayer
import XCTest
@testable import UX_Music_Mobile

final class WatchPlaybackLogicTests: XCTestCase {

    // MARK: - WatchQueueNavigation

    func testNextIndexWrapsToStart() {
        XCTAssertEqual(WatchQueueNavigation.nextIndex(current: 2, count: 3), 0)
    }

    func testNextIndexAdvancesByOne() {
        XCTAssertEqual(WatchQueueNavigation.nextIndex(current: 0, count: 3), 1)
    }

    func testNextIndexIsZeroForEmptyQueue() {
        XCTAssertEqual(WatchQueueNavigation.nextIndex(current: 0, count: 0), 0)
    }

    func testPreviousIndexWrapsToEnd() {
        XCTAssertEqual(WatchQueueNavigation.previousIndex(current: 0, count: 3), 2)
    }

    func testPreviousIndexGoesBackByOne() {
        XCTAssertEqual(WatchQueueNavigation.previousIndex(current: 2, count: 3), 1)
    }

    func testPreviousIndexIsZeroForEmptyQueue() {
        XCTAssertEqual(WatchQueueNavigation.previousIndex(current: 0, count: 0), 0)
    }

    func testShouldRestartOnPreviousIsFalseNearStart() {
        XCTAssertFalse(WatchQueueNavigation.shouldRestartOnPrevious(position: 1))
    }

    func testShouldRestartOnPreviousIsTrueAfterThreshold() {
        XCTAssertTrue(WatchQueueNavigation.shouldRestartOnPrevious(position: 4))
    }

    func testShouldRestartOnPreviousRespectsCustomThreshold() {
        XCTAssertFalse(WatchQueueNavigation.shouldRestartOnPrevious(position: 4, threshold: 5))
    }

    // MARK: - WatchSeekLogic

    func testClampedPositionClampsBelowZero() {
        XCTAssertEqual(WatchSeekLogic.clampedPosition(-10, duration: 120), 0)
    }

    func testClampedPositionClampsAboveDuration() {
        XCTAssertEqual(WatchSeekLogic.clampedPosition(200, duration: 120), 120)
    }

    func testClampedPositionPassesThroughValueInRange() {
        XCTAssertEqual(WatchSeekLogic.clampedPosition(45, duration: 120), 45)
    }

    func testClampedPositionIsZeroForNonPositiveDuration() {
        XCTAssertEqual(WatchSeekLogic.clampedPosition(50, duration: 0), 0)
    }

    // MARK: - WatchNowPlayingInfoBuilder

    private func sampleSong() -> WatchTransferMeta {
        WatchTransferMeta(id: "1", title: "Song", artist: "Artist", album: "Album", duration: 123.4, fileType: "m4a")
    }

    func testBuildInfoReturnsEmptyDictionaryWhenNoSong() {
        XCTAssertTrue(WatchNowPlayingInfoBuilder.buildInfo(for: nil, isPlaying: false, position: 0).isEmpty)
    }

    func testBuildInfoContainsExpectedFields() {
        let info = WatchNowPlayingInfoBuilder.buildInfo(for: sampleSong(), isPlaying: true, position: 12.5)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Song")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Artist")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Album")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 123.4)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12.5)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
    }

    func testBuildInfoPlaybackRateIsZeroWhenPaused() {
        let info = WatchNowPlayingInfoBuilder.buildInfo(for: sampleSong(), isPlaying: false, position: 0)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)
    }
}
