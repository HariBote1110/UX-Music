import XCTest
@testable import UX_Music_Mobile

final class BassOnsetDetectorTests: XCTestCase {

    private let sampleRate = 22_050.0

    func testSixtyHertzBurstsAreDetectedWithoutMisses() {
        let expectedTimes = stride(from: 0.5, through: 4.5, by: 0.5).map { $0 }
        let samples = bassBursts(at: expectedTimes)

        let result = BassOnsetDetector.detect(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(result.times.count, expectedTimes.count)
        for expected in expectedTimes {
            XCTAssertTrue(
                result.times.contains { abs($0 - expected) <= 0.025 },
                "missing bass onset near \(expected)s: \(result.times)"
            )
        }
    }

    func testHighFrequencyNoiseDoesNotProduceBassOnsets() {
        let duration = 5.0
        let count = Int(duration * sampleRate)
        var samples = Array(repeating: Float.zero, count: count)
        var state: UInt32 = 0x1234_5678
        for onset in stride(from: 0.25, through: 4.75, by: 0.125) {
            let start = Int(onset * sampleRate)
            let end = min(start + Int(0.02 * sampleRate), count)
            for index in start..<end {
                state = 1_664_525 &* state &+ 1_013_904_223
                let white = Float(state) / Float(UInt32.max) * 2 - 1
                samples[index] = white * sin(Float(2 * Double.pi * 8_000 * Double(index) / sampleRate))
            }
        }

        let result = BassOnsetDetector.detect(samples: samples, sampleRate: sampleRate)

        XCTAssertLessThanOrEqual(result.times.count, 1, "high-frequency noise leaked into bass band")
    }

    func testSilenceAndConstantLowNoiseProduceNoOnsets() {
        let count = Int(5.0 * sampleRate)
        let silence = Array(repeating: Float.zero, count: count)
        XCTAssertTrue(BassOnsetDetector.detect(samples: silence, sampleRate: sampleRate).times.isEmpty)

        var state: UInt32 = 0x8765_4321
        let lowNoise = (0..<count).map { _ in
            state = 1_664_525 &* state &+ 1_013_904_223
            return (Float(state) / Float(UInt32.max) * 2 - 1) * 0.002
        }
        XCTAssertTrue(BassOnsetDetector.detect(samples: lowNoise, sampleRate: sampleRate).times.isEmpty)
    }

    func testBurstsCloserThanTheMinimumGapCollapseToTheStrongerPeak() {
        let samples = bassBursts(at: [1.0, 1.08], amplitudes: [0.35, 0.9])

        let result = BassOnsetDetector.detect(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(result.times.count, 1)
        XCTAssertGreaterThan(result.strengths[0], 0.5)
    }

    func testOutputIsAscendingAndStrengthsAreNormalised() {
        let result = BassOnsetDetector.detect(
            samples: bassBursts(at: [0.5, 1.0, 1.5], amplitudes: [0.4, 0.8, 0.6]),
            sampleRate: sampleRate
        )

        XCTAssertEqual(result.times, result.times.sorted())
        XCTAssertEqual(result.times.count, result.strengths.count)
        XCTAssertTrue(result.strengths.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    private func bassBursts(at times: [Double], amplitudes: [Float]? = nil) -> [Float] {
        let duration = max(5.0, (times.max() ?? 0) + 0.5)
        let count = Int(duration * sampleRate)
        var samples = Array(repeating: Float.zero, count: count)
        for (burstIndex, onset) in times.enumerated() {
            let start = Int(onset * sampleRate)
            let burstCount = Int(0.08 * sampleRate)
            let amplitude = amplitudes?[burstIndex] ?? 0.8
            for offset in 0..<burstCount where start + offset < count {
                let attack = min(1, Float(offset) / Float(max(1, Int(0.008 * sampleRate))))
                let release = max(0, 1 - Float(offset) / Float(burstCount))
                let envelope = min(attack, release)
                let phase = 2 * Double.pi * 60 * Double(offset) / sampleRate
                samples[start + offset] += amplitude * envelope * Float(sin(phase))
            }
        }
        return samples
    }
}
