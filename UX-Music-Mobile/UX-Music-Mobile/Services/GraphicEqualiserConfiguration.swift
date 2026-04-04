import Foundation

/// 10-band graphic equaliser layout aligned with desktop / `pkg/audio/player.go` (`equalizerFrequencies`).
enum GraphicEqualiserConfiguration {
    static let bandCount = 10

    /// Centre frequencies in Hz (low shelf at 31 Hz, high shelf at 16 kHz, peaking bands between).
    static let centreFrequenciesHz: [Float] = [
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000,
    ]

    /// Matches backend `SetEqualizer` clamp (`-24`…`24` dB).
    static let decibelRange: ClosedRange<Float> = -24 ... 24

    /// Approximate peaking bandwidth in octaves for mid bands (Q ≈ 1.41 on desktop).
    static let parametricBandwidthOctaves: Float = 1

    static func clampedDecibel(_ value: Float) -> Float {
        min(max(value, decibelRange.lowerBound), decibelRange.upperBound)
    }

    /// Named presets (same curve values as `src/renderer/js/ui/equalizer.js`).
    static let presetBandDecibels: [String: [Float]] = [
        "Flat": Array(repeating: 0, count: bandCount),
        "Electronic": [7, 5, 2, 0, -2, 0, 2, 3, 4, 5],
        "Rock": [5, 3, 1, -2, -1, 1, 3, 4, 5, 6],
        "Pop": [-2, 0, 2, 4, 5, 3, 0, -1, -2, -3],
        "Jazz": [4, 2, 1, -2, -2, 0, 1, 2, 3, 4],
        "Classical": [5, 4, 2, -2, -3, -2, 0, 1, 2, 3],
        "Vocal": [-2, -1, 0, 3, 4, 2, 1, 0, -1, -2],
    ]

    static var presetNamesOrdered: [String] {
        ["Flat", "Electronic", "Rock", "Pop", "Jazz", "Classical", "Vocal"]
    }

    static func bands(forPresetNamed name: String) -> [Float]? {
        guard let raw = presetBandDecibels[name] else { return nil }
        return raw.map { clampedDecibel($0) }
    }
}
