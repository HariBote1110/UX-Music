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

    // MARK: - WatchRepeatMode

    func testRepeatModeCyclesOffToAllToOneToOff() {
        XCTAssertEqual(WatchRepeatMode.off.next(), .all)
        XCTAssertEqual(WatchRepeatMode.all.next(), .one)
        XCTAssertEqual(WatchRepeatMode.one.next(), .off)
    }

    // MARK: - WatchQueueNavigation.autoAdvance

    func testAutoAdvanceStopsAtEndWhenRepeatOff() {
        XCTAssertEqual(WatchQueueNavigation.autoAdvance(current: 2, count: 3, repeatMode: .off), .stop)
    }

    func testAutoAdvanceMovesToNextWhenRepeatOffAndNotAtEnd() {
        XCTAssertEqual(WatchQueueNavigation.autoAdvance(current: 0, count: 3, repeatMode: .off), .index(1))
    }

    func testAutoAdvanceWrapsWhenRepeatAll() {
        XCTAssertEqual(WatchQueueNavigation.autoAdvance(current: 2, count: 3, repeatMode: .all), .index(0))
    }

    func testAutoAdvanceStaysOnSameTrackWhenRepeatOne() {
        XCTAssertEqual(WatchQueueNavigation.autoAdvance(current: 1, count: 3, repeatMode: .one), .index(1))
    }

    func testAutoAdvanceStopsForEmptyQueue() {
        XCTAssertEqual(WatchQueueNavigation.autoAdvance(current: 0, count: 0, repeatMode: .all), .stop)
    }

    // MARK: - WatchShuffleLogic

    private func makeSongs(_ ids: [String]) -> [WatchTransferMeta] {
        ids.map { WatchTransferMeta(id: $0, title: $0, artist: "A", album: "Al", duration: 100, fileType: "m4a") }
    }

    func testApplyShuffleReordersAndMovesCurrentToFront() {
        let queue = makeSongs(["A", "B", "C", "D"])
        // permutation: D, B, A, C
        let result = WatchShuffleLogic.applyShuffle(queue: queue, shuffledIndices: [3, 1, 0, 2], currentId: "C")
        XCTAssertEqual(result.map(\.id), ["C", "D", "B", "A"])
    }

    func testApplyShuffleReturnsUnchangedQueueWhenIndicesMismatch() {
        let queue = makeSongs(["A", "B"])
        let result = WatchShuffleLogic.applyShuffle(queue: queue, shuffledIndices: [0], currentId: "A")
        XCTAssertEqual(result.map(\.id), ["A", "B"])
    }

    func testApplyShuffleReturnsShuffledOrderWhenNoCurrentId() {
        let queue = makeSongs(["A", "B", "C"])
        let result = WatchShuffleLogic.applyShuffle(queue: queue, shuffledIndices: [2, 0, 1], currentId: nil)
        XCTAssertEqual(result.map(\.id), ["C", "A", "B"])
    }

    // MARK: - WatchResumeLogic

    func testResolveSongsPreservesOrderAndDropsMissing() {
        let library = makeSongs(["A", "B", "C"])
        let resolved = WatchResumeLogic.resolveSongs(ids: ["C", "X", "A"], librarySongs: library)
        XCTAssertEqual(resolved.map(\.id), ["C", "A"])
    }

    func testResumeIndexFindsMatchingSong() {
        let queue = makeSongs(["A", "B", "C"])
        XCTAssertEqual(WatchResumeLogic.resumeIndex(songId: "B", queue: queue), 1)
    }

    func testResumeIndexIsNilWhenSongMissing() {
        let queue = makeSongs(["A", "B"])
        XCTAssertNil(WatchResumeLogic.resumeIndex(songId: "Z", queue: queue))
    }

    func testResumeStateRoundTripsThroughJSON() throws {
        let state = WatchPlaybackResumeState(
            songId: "B",
            position: 42.5,
            queueSongIds: ["A", "B", "C"],
            originalQueueSongIds: ["A", "B", "C"],
            currentIndex: 1,
            repeatMode: .all,
            isShuffled: true
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WatchPlaybackResumeState.self, from: data)
        XCTAssertEqual(decoded, state)
    }
}
