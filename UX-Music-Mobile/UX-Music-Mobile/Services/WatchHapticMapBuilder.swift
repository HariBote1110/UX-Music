import AVFoundation
import Foundation

/// Decodes a local song into bounded-size mono LPCM chunks, detects bass onsets, and caches the
/// JSON payload that is sent to the Watch. The builder has no main-actor isolation; callers can use
/// it from a detached utility task without holding the UI actor while AVFoundation reads the file.
struct WatchHapticMapBuilder {
    static let detectorSampleRate = 22_050.0

    private static let chunkDuration = 30.0
    private static let overlapDuration = 1.0

    /// Returns the versioned cache file after building it, or `nil` when the source cannot be read
    /// or the payload cannot be persisted. An existing valid cache is reused without decoding audio.
    static func buildFileURL(songId: String, sourceURL: URL) async -> URL? {
        do {
            let cacheURL = try cacheURL(for: songId)
            if let cached = try? Data(contentsOf: cacheURL),
               (try? JSONDecoder().decode(WatchHapticMap.self, from: cached))?.version == WatchHapticMap.currentVersion {
                return cacheURL
            }

            let map = try await build(songId: songId, sourceURL: sourceURL)
            let data = try JSONEncoder().encode(map)
            let temporaryURL = cacheURL.appendingPathExtension("tmp")
            try? FileManager.default.removeItem(at: temporaryURL)
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                try FileManager.default.removeItem(at: cacheURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: cacheURL)
            return cacheURL
        } catch {
            print("[WatchHapticMapBuilder] bass onset map failed for \(songId): \(error.localizedDescription)")
            return nil
        }
    }

    /// Builds the in-memory model. This is kept separate from cache I/O to make the detector/cache
    /// boundary explicit; the public transfer path uses `buildFileURL` so the exact cached bytes are
    /// placed on the WatchConnectivity transfer queue.
    static func build(songId: String, sourceURL: URL) async throws -> WatchHapticMap {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw BuilderError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: detectorSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw BuilderError.cannotAddOutput }
        reader.add(output)
        guard reader.startReading() else {
            throw BuilderError.readerFailed(reader.error?.localizedDescription ?? "reader did not start")
        }

        let chunkSamples = Int(chunkDuration * detectorSampleRate)
        let overlapSamples = Int(overlapDuration * detectorSampleRate)
        var bufferedSamples: [Float] = []
        var bufferedStartSample = 0
        var onsets: [(time: Double, strength: Float)] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try appendSamples(from: sampleBuffer, to: &bufferedSamples)
            while bufferedSamples.count >= chunkSamples {
                let chunk = Array(bufferedSamples.prefix(chunkSamples))
                append(
                    BassOnsetDetector.detect(samples: chunk, sampleRate: detectorSampleRate),
                    offsetSamples: bufferedStartSample,
                    to: &onsets
                )
                let consumed = chunkSamples - overlapSamples
                bufferedSamples.removeFirst(consumed)
                bufferedStartSample += consumed
            }
        }

        guard reader.status != .failed else {
            throw BuilderError.readerFailed(reader.error?.localizedDescription ?? "reader failed")
        }
        if !bufferedSamples.isEmpty {
            append(
                BassOnsetDetector.detect(samples: bufferedSamples, sampleRate: detectorSampleRate),
                offsetSamples: bufferedStartSample,
                to: &onsets
            )
        }

        let merged = merge(onsets)
        return WatchHapticMap(
            version: WatchHapticMap.currentVersion,
            songId: songId,
            onsetTimes: merged.map { $0.time },
            strengths: merged.map { $0.strength }
        )
    }

    private enum BuilderError: LocalizedError {
        case noAudioTrack
        case cannotAddOutput
        case readerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "no audio track"
            case .cannotAddOutput: return "cannot add audio reader output"
            case .readerFailed(let reason): return reason
            }
        }
    }

    private static func cacheURL(for songId: String) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches.appendingPathComponent("WatchHaptics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(
            "\(WatchTransferMeta.storageStem(for: songId))-v\(WatchHapticMap.currentVersion).json"
        )
    }

    private static func appendSamples(from sampleBuffer: CMSampleBuffer, to samples: inout [Float]) throws {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw BuilderError.readerFailed("audio sample buffer has no data")
        }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        let floatStride = MemoryLayout<Float>.stride
        guard totalLength > 0, totalLength.isMultiple(of: floatStride) else {
            throw BuilderError.readerFailed("audio sample buffer data is not Float32-aligned")
        }

        // `CMBlockBufferGetDataPointer` may return only the first contiguous segment. Copying the
        // complete block first keeps this safe for fragmented buffers as well as contiguous ones.
        var copiedSamples = [Float](repeating: 0, count: totalLength / floatStride)
        let status = copiedSamples.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw BuilderError.readerFailed("audio sample buffer data is inaccessible")
        }

        let count = min(CMSampleBufferGetNumSamples(sampleBuffer), copiedSamples.count)
        samples.append(contentsOf: copiedSamples.prefix(count))
    }

    private static func append(
        _ result: (times: [Double], strengths: [Float]),
        offsetSamples: Int,
        to onsets: inout [(time: Double, strength: Float)]
    ) {
        let offset = Double(offsetSamples) / detectorSampleRate
        onsets.append(contentsOf: zip(result.times, result.strengths).map { ($0 + offset, $1) })
    }

    private static func merge(_ onsets: [(time: Double, strength: Float)]) -> [(time: Double, strength: Float)] {
        let sorted = onsets.sorted { $0.time < $1.time }
        var result: [(time: Double, strength: Float)] = []
        for onset in sorted {
            guard let previous = result.last else {
                result.append(onset)
                continue
            }
            guard onset.time - previous.time < WatchHapticMap.minimumOnsetGap else {
                result.append(onset)
                continue
            }
            if onset.strength > previous.strength {
                result[result.count - 1] = onset
            }
        }
        return result
    }
}
