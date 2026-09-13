import Accelerate
import Foundation

/// Pure, frame-based bass-onset detector. It deliberately has no AVFoundation dependency so the
/// signal-processing core can be exercised with deterministic synthetic samples in unit tests.
struct BassOnsetDetector {
    private static let frameSize = 2_048
    private static let hopSize = 512
    private static let lowFrequency = 30.0
    private static let highFrequency = 150.0
    private static let thresholdWindowSeconds = 1.0
    private static let thresholdMADMultiplier: Float = 3.0
    private static let minimumRelativePeak: Float = 0.08
    private static let minimumBassEnergyRatio: Float = 0.05
    private static let onsetSearchRadiusSeconds = 0.05
    private static let onsetEnvelopeWindowSeconds = 0.002
    private static let onsetEnvelopeThreshold: Float = 0.5

    private struct SpectralFeature {
        let logBandEnergy: Float
        let bandEnergyRatio: Float
    }

    static func detect(samples: [Float], sampleRate: Double) -> (times: [Double], strengths: [Float]) {
        guard sampleRate.isFinite, sampleRate > 0, samples.count >= frameSize else {
            return ([], [])
        }

        let frameCount = 1 + (samples.count - frameSize) / hopSize
        guard frameCount >= 2 else { return ([], []) }
        let window = hannWindow(count: frameSize)
        let features = spectralFeatures(
            samples: samples,
            sampleRate: sampleRate,
            frameCount: frameCount,
            window: window
        )
        let flux = features.indices.map { index in
            guard index > 0 else { return Float.zero }
            return max(0, features[index].logBandEnergy - features[index - 1].logBandEnergy)
        }
        guard let maximumFlux = flux.max(), maximumFlux > 0 else { return ([], []) }

        let thresholdRadius = max(1, Int((thresholdWindowSeconds * sampleRate) / Double(hopSize) / 2))
        var candidates: [(frame: Int, strength: Float)] = []
        for frame in 1..<(flux.count - 1) {
            let value = flux[frame]
            guard value > 0,
                  features[frame].bandEnergyRatio >= minimumBassEnergyRatio,
                  value >= flux[frame - 1],
                  value >= flux[frame + 1]
            else { continue }

            let lower = max(0, frame - thresholdRadius)
            let upper = min(flux.count - 1, frame + thresholdRadius)
            let local = Array(flux[lower...upper])
            let median = percentile(local, 0.5)
            let mad = percentile(local.map { abs($0 - median) }, 0.5)
            let threshold = max(
                median + thresholdMADMultiplier * mad,
                maximumFlux * minimumRelativePeak
            )
            guard value > threshold else { continue }
            candidates.append((frame, value))
        }

        // Strongest-first suppression makes the minimum-gap rule deterministic: if two attacks
        // fall inside the 125 ms haptic window, the more prominent bass hit wins.
        let selected = candidates
            .sorted {
                if $0.strength != $1.strength { return $0.strength > $1.strength }
                return $0.frame < $1.frame
            }
            .reduce(into: [(frame: Int, strength: Float)]()) { result, candidate in
                let candidateTime = Double(candidate.frame * hopSize) / sampleRate
                guard result.allSatisfy({
                    abs(Double($0.frame * hopSize) / sampleRate - candidateTime) >= WatchHapticMap.minimumOnsetGap
                }) else { return }
                result.append(candidate)
            }
            .sorted { $0.frame < $1.frame }

        guard let strongest = selected.map({ $0.strength }).max(), strongest > 0 else {
            return ([], [])
        }
        // Flux belongs to the complete analysis window. Use its centre only as an anchor, then
        // align the timestamp to the first rising edge in the raw-sample RMS envelope.
        let frameCentre = Double(frameSize) / (2 * sampleRate)
        let times = selected.map { candidate in
            onsetAlignedTime(
                samples: samples,
                sampleRate: sampleRate,
                frame: candidate.frame,
                fallback: Double(candidate.frame * hopSize) / sampleRate + frameCentre
            )
        }
        let strengths = selected.map { min(1, max(0, $0.strength / strongest)) }
        return (times, strengths)
    }

    private static func hannWindow(count: Int) -> [Float] {
        guard count > 1 else { return Array(repeating: 1, count: count) }
        return (0..<count).map { index in
            Float(0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count - 1)))
        }
    }

    private static func spectralFeatures(
        samples: [Float],
        sampleRate: Double,
        frameCount: Int,
        window: [Float]
    ) -> [SpectralFeature] {
        let log2FrameSize = vDSP_Length(round(log2(Double(frameSize))))
        guard let setup = vDSP_create_fftsetup(log2FrameSize, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let firstBin = max(1, Int(floor(lowFrequency * Double(frameSize) / sampleRate)))
        let lastBin = min(frameSize / 2 - 1, Int(ceil(highFrequency * Double(frameSize) / sampleRate)))
        guard firstBin <= lastBin else { return [] }

        var result: [SpectralFeature] = []
        result.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let start = frame * hopSize
            var real = Array(repeating: Float.zero, count: frameSize / 2)
            var imaginary = Array(repeating: Float.zero, count: frameSize / 2)
            var interleaved = Array(repeating: Float.zero, count: frameSize)
            for index in 0..<frameSize {
                interleaved[index] = samples[start + index] * window[index]
            }

            let feature: SpectralFeature = real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    interleaved.withUnsafeBufferPointer { inputBuffer in
                        var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                        inputBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frameSize / 2) { complexBuffer in
                            vDSP_ctoz(complexBuffer, 2, &split, 1, vDSP_Length(frameSize / 2))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2FrameSize, FFTDirection(FFT_FORWARD))

                        var bandEnergy: Float = 0
                        var totalEnergy: Float = 0
                        for bin in 1..<(frameSize / 2) {
                            let energy = split.realp[bin] * split.realp[bin] + split.imagp[bin] * split.imagp[bin]
                            totalEnergy += energy
                            if (firstBin...lastBin).contains(bin) {
                                bandEnergy += energy
                            }
                        }
                        return SpectralFeature(
                            logBandEnergy: log1p(bandEnergy),
                            bandEnergyRatio: bandEnergy / max(totalEnergy, Float.ulpOfOne)
                        )
                    }
                }
            }
            result.append(feature)
        }
        return result
    }

    private static func onsetAlignedTime(
        samples: [Float],
        sampleRate: Double,
        frame: Int,
        fallback: Double
    ) -> Double {
        let centreSample = frame * hopSize + frameSize / 2
        let searchRadius = max(1, Int(onsetSearchRadiusSeconds * sampleRate))
        let envelopeWindow = max(1, Int(onsetEnvelopeWindowSeconds * sampleRate))
        let firstStart = max(0, centreSample - searchRadius)
        let lastStart = min(samples.count - envelopeWindow, centreSample + searchRadius)
        guard firstStart <= lastStart else { return fallback }

        var energy = samples[firstStart..<firstStart + envelopeWindow].reduce(Float.zero) { partial, sample in
            partial + sample * sample
        }
        var envelope = Array(repeating: Float.zero, count: lastStart - firstStart + 1)
        envelope[0] = sqrt(max(0, energy) / Float(envelopeWindow))
        for index in 1..<envelope.count {
            energy -= samples[firstStart + index - 1] * samples[firstStart + index - 1]
            let addedIndex = firstStart + index + envelopeWindow - 1
            energy += samples[addedIndex] * samples[addedIndex]
            envelope[index] = sqrt(max(0, energy) / Float(envelopeWindow))
        }

        guard let peak = envelope.max(), peak > 0 else { return fallback }
        let crossing = envelope.firstIndex { $0 >= peak * onsetEnvelopeThreshold } ?? 0
        return Double(firstStart + crossing) / sampleRate
    }

    private static func percentile(_ values: [Float], _ fraction: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(round(fraction * Float(sorted.count - 1)))))
        return sorted[index]
    }
}
