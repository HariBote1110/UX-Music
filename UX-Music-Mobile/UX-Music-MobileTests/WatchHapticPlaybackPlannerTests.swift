import XCTest
@testable import UX_Music_Mobile

final class WatchHapticPlaybackPlannerTests: XCTestCase {

    func testMapsMediaTimeToUptimeUsingSnapshotRate() {
        let snapshot = WatchHapticPlaybackClockSnapshot(
            mediaTime: 10,
            capturedUptime: 100,
            rate: 2,
            songId: "song"
        )

        XCTAssertEqual(
            WatchHapticPlaybackPlanner.uptime(
                forMediaTime: 12,
                snapshot: snapshot
            ),
            101
        )
    }

    func testDoesNotMapWhenRateIsNotPositive() {
        let snapshot = WatchHapticPlaybackClockSnapshot(
            mediaTime: 10,
            capturedUptime: 100,
            rate: 0,
            songId: "song"
        )

        XCTAssertNil(WatchHapticPlaybackPlanner.uptime(forMediaTime: 12, snapshot: snapshot))
    }

    func testContinuousHalfSecondClockUpdateIsNotDiscontinuity() {
        let previous = WatchHapticPlaybackClockSnapshot(
            mediaTime: 10,
            capturedUptime: 100,
            rate: 1,
            songId: "song"
        )
        let next = WatchHapticPlaybackClockSnapshot(
            mediaTime: 10.5,
            capturedUptime: 100.5,
            rate: 1,
            songId: "song"
        )

        XCTAssertFalse(
            WatchHapticPlaybackPlanner.isDiscontinuity(
                previous: previous,
                next: next
            )
        )
    }

    func testSeekForwardAndBackwardAreDiscontinuities() {
        let previous = WatchHapticPlaybackClockSnapshot(
            mediaTime: 10,
            capturedUptime: 100,
            rate: 1,
            songId: "song"
        )
        let seekForward = WatchHapticPlaybackClockSnapshot(
            mediaTime: 20,
            capturedUptime: 100.5,
            rate: 1,
            songId: "song"
        )
        let seekBackward = WatchHapticPlaybackClockSnapshot(
            mediaTime: 1,
            capturedUptime: 101,
            rate: 1,
            songId: "song"
        )

        XCTAssertTrue(
            WatchHapticPlaybackPlanner.isDiscontinuity(
                previous: previous,
                next: seekForward
            )
        )
        XCTAssertTrue(
            WatchHapticPlaybackPlanner.isDiscontinuity(
                previous: previous,
                next: seekBackward
            )
        )
        XCTAssertEqual(
            WatchHapticPlaybackPlanner.resumeIndex(
                onsetTimes: [1, 5, 10, 20],
                audibleMediaTime: 20,
                lastFiredMediaTime: nil
            ),
            3
        )
        XCTAssertEqual(
            WatchHapticPlaybackPlanner.resumeIndex(
                onsetTimes: [1, 5, 10, 20],
                audibleMediaTime: 1,
                lastFiredMediaTime: nil
            ),
            0
        )
    }

    func testFindsFirstOnsetAtOrAfterMediaTime() {
        XCTAssertEqual(
            WatchHapticPlaybackPlanner.nextOnsetIndex(
                forMediaTime: 1.25,
                onsetTimes: [0.5, 1.25, 2.0]
            ),
            1
        )
        XCTAssertEqual(
            WatchHapticPlaybackPlanner.nextOnsetIndex(
                forMediaTime: 3,
                onsetTimes: [0.5, 1.25, 2.0]
            ),
            3
        )
    }

    func testAddsOutputLatencyToSpeakerArrivalUptime() throws {
        let snapshot = WatchHapticPlaybackClockSnapshot(
            mediaTime: 10,
            capturedUptime: 100,
            rate: 1,
            songId: "song"
        )

        XCTAssertEqual(
            try XCTUnwrap(WatchHapticPlaybackPlanner.fireUptime(
                forMediaTime: 12,
                snapshot: snapshot,
                outputLatency: 0.08
            )),
            102.08,
            accuracy: 0.000_001
        )
    }

    func testResumeIndexKeepsOnsetWithinOutputLatencyWindow() {
        let snapshot = WatchHapticPlaybackClockSnapshot(
            mediaTime: 10,
            capturedUptime: 100,
            rate: 1,
            songId: "song"
        )
        let audibleMediaTime = WatchHapticPlaybackPlanner.audibleMediaTime(
            snapshot: snapshot,
            now: 100,
            outputLatency: 0.2
        )

        guard let audibleMediaTime else {
            return XCTFail("Expected an audible media time")
        }
        XCTAssertEqual(audibleMediaTime, 9.8, accuracy: 0.000_001)
        XCTAssertEqual(
            WatchHapticPlaybackPlanner.resumeIndex(
                onsetTimes: [9.9, 10.1],
                audibleMediaTime: audibleMediaTime,
                lastFiredMediaTime: nil
            ),
            0
        )
    }

    func testResumeIndexDoesNotRefireAnOnsetAtOrBeforeLastFiredMediaTime() {
        XCTAssertEqual(
            WatchHapticPlaybackPlanner.resumeIndex(
                onsetTimes: [9.9, 10, 10.1],
                audibleMediaTime: 9.8,
                lastFiredMediaTime: 10
            ),
            2
        )
    }

    func testFiltersWeakOnsetsAndEnforcesMinimumGap() {
        let result = WatchHapticPlaybackPlanner.filteredOnsets(
            onsetTimes: [0, 0.1, 0.2, 0.4, 0.5],
            strengths: [0.9, 0.8, 0.2, 0.7, 0.6],
            strengthThreshold: 0.25,
            minimumGap: 0.18
        )

        XCTAssertEqual(result.map(\.time), [0, 0.4])
        XCTAssertEqual(result.map(\.strength), [0.9, 0.7])
    }

    func testLateSkipStartsAfterSixtyMilliseconds() {
        XCTAssertFalse(
            WatchHapticPlaybackPlanner.shouldSkipLate(
                fireUptime: 10,
                now: 10.06
            )
        )
        XCTAssertTrue(
            WatchHapticPlaybackPlanner.shouldSkipLate(
                fireUptime: 10,
                now: 10.061
            )
        )
    }
}
