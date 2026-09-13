import XCTest
@testable import UX_Music_Mobile

final class WatchHapticBeatScheduleTests: XCTestCase {

    func testIntervalUsesBPMAndSubdivision() throws {
        let halfBeat = try XCTUnwrap(WatchHapticBeatSchedule(bpm: 120, subdivision: 2))
        let slowBeat = try XCTUnwrap(WatchHapticBeatSchedule(bpm: 40, subdivision: 1))
        let fastSubdivision = try XCTUnwrap(WatchHapticBeatSchedule(bpm: 240, subdivision: 4))

        XCTAssertEqual(
            halfBeat.interval,
            0.25,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(
            slowBeat.interval,
            1.5,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(
            fastSubdivision.interval,
            0.0625,
            accuracy: 0.000_000_001
        )
    }

    func testScheduleRejectsValuesOutsideTheExperimentRange() {
        XCTAssertNil(WatchHapticBeatSchedule(bpm: 39, subdivision: 1))
        XCTAssertNil(WatchHapticBeatSchedule(bpm: 241, subdivision: 1))
        XCTAssertNil(WatchHapticBeatSchedule(bpm: 120, subdivision: 3))
    }

    func testDeadlineIsDerivedFromStartAndTickWithoutAccumulation() {
        let schedule = try! XCTUnwrap(WatchHapticBeatSchedule(bpm: 120, subdivision: 2))

        XCTAssertEqual(schedule.deadline(forTick: 0, startUptime: 10), 10, accuracy: 0.000_000_001)
        XCTAssertEqual(schedule.deadline(forTick: 3, startUptime: 10), 10.75, accuracy: 0.000_000_001)
        XCTAssertEqual(
            schedule.deadline(forTick: 100, startUptime: 10),
            35,
            accuracy: 0.000_000_001
        )
    }

    func testNextTickSkipsLateDeadlinesToTheCurrentTick() {
        let schedule = try! XCTUnwrap(WatchHapticBeatSchedule(bpm: 120, subdivision: 2))

        XCTAssertEqual(
            schedule.nextTick(after: 100.81, startUptime: 100, tolerance: schedule.interval * 0.25),
            3
        )
    }

    func testNextTickKeepsTheFollowingTickWhenHandlerIsOnTime() {
        let schedule = try! XCTUnwrap(WatchHapticBeatSchedule(bpm: 120, subdivision: 2))

        XCTAssertEqual(
            schedule.nextTick(after: 100.10, startUptime: 100, tolerance: schedule.interval * 0.25),
            1
        )
    }

    func testLatenessStatisticsUseNearestRankPercentilesInMilliseconds() {
        let pairs: [(scheduled: TimeInterval, fired: TimeInterval)] = [
            (100, 100.010),
            (100, 100.020),
            (100, 100.015),
            (100, 100.100),
        ]

        let statistics = WatchHapticLatenessStatistics(pairs: pairs, skipped: 3)

        XCTAssertEqual(statistics.count, 4)
        XCTAssertEqual(statistics.skipped, 3)
        XCTAssertEqual(statistics.p50Milliseconds, 15, accuracy: 0.000_001)
        XCTAssertEqual(statistics.p95Milliseconds, 100, accuracy: 0.000_001)
        XCTAssertEqual(statistics.maxMilliseconds, 100, accuracy: 0.000_001)
    }

    func testLatenessStatisticsForNoTicksAreZero() {
        let statistics = WatchHapticLatenessStatistics(pairs: [])

        XCTAssertEqual(statistics.count, 0)
        XCTAssertEqual(statistics.skipped, 0)
        XCTAssertEqual(statistics.p50Milliseconds, 0)
        XCTAssertEqual(statistics.p95Milliseconds, 0)
        XCTAssertEqual(statistics.maxMilliseconds, 0)
    }
}
