import Foundation

/// A point-in-time bridge between AVPlayer media time and the monotonic host clock.
struct WatchHapticPlaybackClockSnapshot: Equatable, Sendable {
    let mediaTime: Double
    let capturedUptime: TimeInterval
    let rate: Float
    let songId: String?
}

struct WatchHapticOnset: Equatable, Sendable {
    let time: Double
    let strength: Float
}

/// Pure scheduling rules for Watch haptic playback. It deliberately has no AVFoundation,
/// WatchKit, or filesystem dependency so timing decisions remain testable on iOS.
enum WatchHapticPlaybackPlanner {
    static let defaultStrengthThreshold: Float = 0.25
    // The device has only verified 0.125 s spacing with `.click`; `.failure` is longer.
    static let defaultMinimumGap: TimeInterval = 0.18
    static let lateSkipTolerance: TimeInterval = 0.060
    static let defaultDiscontinuityTolerance: TimeInterval = 0.25

    /// Distinguishes a normal clock publication from a song/rate change or seek. The media time
    /// expected at `next.capturedUptime` is projected from the previous sample, so a regular
    /// 0.5-second publication is not mistaken for a seek.
    static func isDiscontinuity(
        previous: WatchHapticPlaybackClockSnapshot?,
        next: WatchHapticPlaybackClockSnapshot,
        tolerance: TimeInterval = defaultDiscontinuityTolerance
    ) -> Bool {
        guard let previous else { return true }
        guard previous.songId == next.songId,
              previous.rate == next.rate,
              previous.mediaTime.isFinite,
              previous.capturedUptime.isFinite,
              next.mediaTime.isFinite,
              next.capturedUptime.isFinite
        else { return true }

        let projectedMediaTime = previous.mediaTime
            + Double(previous.rate) * (next.capturedUptime - previous.capturedUptime)
        return abs(next.mediaTime - projectedMediaTime) > max(0, tolerance)
    }

    /// Projects `mediaTime` from the latest clock sample onto the monotonic host clock.
    static func uptime(
        forMediaTime mediaTime: Double,
        snapshot: WatchHapticPlaybackClockSnapshot
    ) -> TimeInterval? {
        guard snapshot.rate > 0,
              snapshot.mediaTime.isFinite,
              mediaTime.isFinite,
              snapshot.capturedUptime.isFinite
        else { return nil }

        return snapshot.capturedUptime + (mediaTime - snapshot.mediaTime) / Double(snapshot.rate)
    }

    /// Returns the first onset at or after `mediaTime`, or `onsetTimes.count` when exhausted.
    static func nextOnsetIndex(forMediaTime mediaTime: Double, onsetTimes: [Double]) -> Int {
        var lower = 0
        var upper = onsetTimes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if onsetTimes[middle] < mediaTime {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    /// Returns media time that has reached the listener at `now`, accounting for output latency.
    static func audibleMediaTime(
        snapshot: WatchHapticPlaybackClockSnapshot,
        now: TimeInterval,
        outputLatency: TimeInterval
    ) -> Double? {
        guard snapshot.rate > 0,
              snapshot.mediaTime.isFinite,
              snapshot.capturedUptime.isFinite,
              now.isFinite
        else { return nil }

        let mediaTimeAtNow = snapshot.mediaTime
            + Double(snapshot.rate) * (now - snapshot.capturedUptime)
        return mediaTimeAtNow - Double(snapshot.rate) * max(0, outputLatency)
    }

    /// Returns the first onset audible at or after the current point, while preventing a seek
    /// within the same stream from replaying an onset that has already fired.
    static func resumeIndex(
        onsetTimes: [Double],
        audibleMediaTime: Double,
        lastFiredMediaTime: Double?
    ) -> Int {
        guard audibleMediaTime.isFinite else { return onsetTimes.count }

        var index = nextOnsetIndex(
            forMediaTime: audibleMediaTime,
            onsetTimes: onsetTimes
        )
        if let lastFiredMediaTime, lastFiredMediaTime.isFinite {
            while index < onsetTimes.count,
                  onsetTimes[index] <= lastFiredMediaTime {
                index += 1
            }
        }
        return index
    }

    /// Returns the monotonic time at which the onset reaches the listener, including output
    /// latency measured from AVAudioSession on a background queue.
    static func fireUptime(
        forMediaTime mediaTime: Double,
        snapshot: WatchHapticPlaybackClockSnapshot,
        outputLatency: TimeInterval
    ) -> TimeInterval? {
        guard let projected = uptime(forMediaTime: mediaTime, snapshot: snapshot) else { return nil }
        return projected + max(0, outputLatency)
    }

    /// Applies the strength threshold and the minimum time between selected haptic firings.
    /// The input is expected to be ascending, as are maps produced by the iPhone.
    static func filteredOnsets(
        onsetTimes: [Double],
        strengths: [Float],
        strengthThreshold: Float = defaultStrengthThreshold,
        minimumGap: TimeInterval = defaultMinimumGap
    ) -> [WatchHapticOnset] {
        var result: [WatchHapticOnset] = []
        var lastSelectedTime: Double?
        let gap = max(0, minimumGap)

        for (time, strength) in zip(onsetTimes, strengths) {
            guard time.isFinite, strength.isFinite, strength >= strengthThreshold else { continue }
            if let lastSelectedTime, time - lastSelectedTime < gap {
                continue
            }
            result.append(WatchHapticOnset(time: time, strength: strength))
            lastSelectedTime = time
        }
        return result
    }

    /// A timer wake is too late to be useful once it exceeds the tolerance. Such an onset is
    /// counted as skipped and the scheduler advances without emitting a burst.
    static func shouldSkipLate(
        fireUptime: TimeInterval,
        now: TimeInterval,
        tolerance: TimeInterval = lateSkipTolerance
    ) -> Bool {
        now - fireUptime > max(0, tolerance) + 0.000_000_001
    }
}
