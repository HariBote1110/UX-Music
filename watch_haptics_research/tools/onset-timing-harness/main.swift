import Foundation

private let sampleRate = 22_050.0
private var phaseAssertionsPassed = true
private var timingAssertionsPassed = true
private var otherAssertionsPassed = true

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

private func highFrequencyNoise() -> [Float] {
    let count = Int(5.0 * sampleRate)
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
    return samples
}

private func lowNoise() -> [Float] {
    let count = Int(5.0 * sampleRate)
    var state: UInt32 = 0x8765_4321
    return (0..<count).map { _ in
        state = 1_664_525 &* state &+ 1_013_904_223
        return (Float(state) / Float(UInt32.max) * 2 - 1) * 0.002
    }
}

private func maximumError(for shift: Double) -> (Double, [Double]) {
    let expected = stride(from: 0.5 + shift, through: 4.5 + shift, by: 0.5).map { $0 }
    let result = BassOnsetDetector.detect(samples: bassBursts(at: expected), sampleRate: sampleRate)
    let errors = expected.map { target in
        result.times.map { abs($0 - target) }.min() ?? .infinity
    }
    return (errors.max() ?? .infinity, errors)
}

private func requirePhase(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        phaseAssertionsPassed = false
        print("FAIL: \(message)")
    }
}

private func requireTiming(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        timingAssertionsPassed = false
        print("FAIL: \(message)")
    }
}

private func requireOther(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        otherAssertionsPassed = false
        print("FAIL: \(message)")
    }
}

let shifts = [0.0, 0.007, 0.013]
print("phase variant measurements")
for shift in shifts {
    let (maximum, errors) = maximumError(for: shift)
    print(String(format: "shift %+0.3f s | max|error| %0.3f ms | errors %@", shift, maximum * 1_000,
                 errors.map { String(format: "%0.1f", $0 * 1_000) }.joined(separator: ", ")))
    requirePhase(maximum <= 0.015, "phase shift \(shift)s exceeds 15 ms")
}

let expectedTimes = stride(from: 0.5, through: 4.5, by: 0.5).map { $0 }
let burstResult = BassOnsetDetector.detect(samples: bassBursts(at: expectedTimes), sampleRate: sampleRate)
requireTiming(burstResult.times.count == expectedTimes.count, "60 Hz burst count")
for expected in expectedTimes {
    requireTiming(burstResult.times.contains { abs($0 - expected) <= 0.025 }, "60 Hz burst near \(expected)s")
}

let highFrequencyResult = BassOnsetDetector.detect(samples: highFrequencyNoise(), sampleRate: sampleRate)
requireOther(highFrequencyResult.times.count <= 1, "high-frequency noise leaked into bass band")

let silence = Array(repeating: Float.zero, count: Int(5.0 * sampleRate))
requireOther(BassOnsetDetector.detect(samples: silence, sampleRate: sampleRate).times.isEmpty, "silence")
requireOther(BassOnsetDetector.detect(samples: lowNoise(), sampleRate: sampleRate).times.isEmpty, "constant low noise")

let closeResult = BassOnsetDetector.detect(
    samples: bassBursts(at: [1.0, 1.08], amplitudes: [0.35, 0.9]),
    sampleRate: sampleRate
)
requireOther(closeResult.times.count == 1, "minimum-gap suppression")
requireOther(closeResult.strengths[0] > 0.5, "stronger close peak")

let normalisedResult = BassOnsetDetector.detect(
    samples: bassBursts(at: [0.5, 1.0, 1.5], amplitudes: [0.4, 0.8, 0.6]),
    sampleRate: sampleRate
)
requireOther(normalisedResult.times == normalisedResult.times.sorted(), "ascending output")
requireOther(normalisedResult.times.count == normalisedResult.strengths.count, "matching output lengths")
requireOther(normalisedResult.strengths.allSatisfy { $0 >= 0 && $0 <= 1 }, "normalised strengths")
let phaseStatus = phaseAssertionsPassed ? "PASS" : "FAIL"
let timingStatus = timingAssertionsPassed ? "PASS" : "FAIL"
let otherStatus = otherAssertionsPassed ? "PASS" : "FAIL"
print("phase assertions: \(phaseStatus)")
print("60 Hz timing assertions: \(timingStatus)")
print("other test assertions: \(otherStatus)")

let longSamples = bassBursts(at: stride(from: 0.5, through: 29.5, by: 0.5).map { $0 })
let start = DispatchTime.now().uptimeNanoseconds
_ = BassOnsetDetector.detect(samples: longSamples, sampleRate: sampleRate)
let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
print(String(format: "processing time for 30 s: %0.2f ms", elapsedMilliseconds))
if !phaseAssertionsPassed || !timingAssertionsPassed || !otherAssertionsPassed {
    exit(1)
}
