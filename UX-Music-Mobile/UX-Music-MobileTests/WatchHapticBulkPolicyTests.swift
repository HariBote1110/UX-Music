import XCTest
@testable import UX_Music_Mobile

final class WatchHapticBulkPolicyTests: XCTestCase {

    func testCandidatesUseCompletedIDsWhenWatchHasNotReported() {
        let available = URL(fileURLWithPath: "/tmp/song-a.m4a")
        let candidates = WatchHapticBulkPlanning.candidates(
            watchReportedSongIDs: nil,
            completedAudioSongIDs: ["song-c", "song-a", "song-b"],
            localSourceURLs: ["song-a": available]
        )

        XCTAssertEqual(candidates, [
            .init(songId: "song-a", sourceURL: available),
            .init(songId: "song-b", sourceURL: nil),
            .init(songId: "song-c", sourceURL: nil)
        ])
    }

    func testCandidatesPreferTheWatchReportAndDropDeletedCompletedIDs() {
        let candidates = WatchHapticBulkPlanning.candidates(
            watchReportedSongIDs: ["song-b", "song-a", "song-b"],
            completedAudioSongIDs: ["song-a", "song-deleted", "song-b"],
            localSourceURLs: [:]
        )

        XCTAssertEqual(candidates.map(\.songId), ["song-b", "song-a"])
    }

    func testCandidatesDeduplicateCompletedIDsInStableOrder() {
        let candidates = WatchHapticBulkPlanning.candidates(
            watchReportedSongIDs: nil,
            completedAudioSongIDs: ["song-c", "song-a", "song-c", "song-b", "song-a"],
            localSourceURLs: [:]
        )

        XCTAssertEqual(candidates.map(\.songId), ["song-a", "song-b", "song-c"])
    }

    func testProgressCountsSuccessAndFailureSequentially() {
        var progress = WatchHapticBulkProgress(total: 2, completed: 0, failed: 0, isFinished: false)

        progress = WatchHapticBulkPlanning.progress(after: progress, succeeded: true)
        XCTAssertEqual(progress, .init(total: 2, completed: 1, failed: 0, isFinished: false))

        progress = WatchHapticBulkPlanning.progress(after: progress, succeeded: false)
        XCTAssertEqual(progress, .init(total: 2, completed: 1, failed: 1, isFinished: false))
    }
}
