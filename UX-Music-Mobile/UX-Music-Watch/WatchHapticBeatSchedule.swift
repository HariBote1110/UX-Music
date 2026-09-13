#if DEBUG
import Foundation

/// Drift-free timing parameters for the Haptics Lab experiment.
struct WatchHapticBeatSchedule: Equatable, Sendable {
    let bpm: Int
    let subdivision: Int
    let interval: TimeInterval

    init?(bpm: Int, subdivision: Int) {
        guard (40...240).contains(bpm), [1, 2, 4].contains(subdivision) else {
            return nil
        }

        self.bpm = bpm
        self.subdivision = subdivision
        interval = 60 / Double(bpm * subdivision)
    }

    /// Returns `startUptime + tick * interval`; callers must not feed the result back into the
    /// next deadline, which would accumulate timer error.
    func deadline(forTick tick: Int, startUptime: TimeInterval) -> TimeInterval {
        startUptime + Double(tick) * interval
    }

    /// Returns the first non-negative tick whose deadline is at or after `now - tolerance`.
    func nextTick(
        after now: TimeInterval,
        startUptime: TimeInterval,
        tolerance: TimeInterval
    ) -> Int {
        let earliestAcceptedDeadline = now - max(0, tolerance)
        let tick = Int(ceil((earliestAcceptedDeadline - startUptime) / interval))
        return max(0, tick)
    }
}

/// Summary of fired-minus-scheduled uptime deltas for the Haptics Lab log.
struct WatchHapticLatenessStatistics: Equatable, Sendable {
    let count: Int
    let skipped: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double

    init(
        pairs: [(scheduled: TimeInterval, fired: TimeInterval)],
        skipped: Int = 0
    ) {
        let lateness = pairs
            .map { ($0.fired - $0.scheduled) * 1_000 }
            .sorted()

        count = lateness.count
        self.skipped = max(0, skipped)
        guard !lateness.isEmpty else {
            p50Milliseconds = 0
            p95Milliseconds = 0
            maxMilliseconds = 0
            return
        }

        p50Milliseconds = Self.nearestRankPercentile(lateness, probability: 0.50)
        p95Milliseconds = Self.nearestRankPercentile(lateness, probability: 0.95)
        maxMilliseconds = lateness[lateness.count - 1]
    }

    /// Uses the nearest-rank definition so p95 remains meaningful for the small samples produced
    /// by a short real-device run.
    private static func nearestRankPercentile(_ sortedValues: [Double], probability: Double) -> Double {
        let rank = max(1, Int(ceil(probability * Double(sortedValues.count))))
        return sortedValues[rank - 1]
    }
}
#endif
