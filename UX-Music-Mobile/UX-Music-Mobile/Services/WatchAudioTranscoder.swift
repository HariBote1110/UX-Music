import AVFoundation
import Foundation

/// Transcodes a local audio file to AAC-LC 128 kbps stereo 44.1 kHz in an `.m4a` container, for
/// transfer to the Apple Watch when `WatchTransferAudioPolicy.decision(...)` says `.transcode`
/// (see that type for the rationale).
struct WatchAudioTranscoder {
    enum TranscodeError: LocalizedError {
        case noAudioTrack
        case readerFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "音声トラックが見つかりません"
            case .readerFailed(let reason): return "読み込みに失敗しました: \(reason)"
            case .writerFailed(let reason): return "書き出しに失敗しました: \(reason)"
            }
        }
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Transcodes `source` to AAC-LC 128 kbps m4a, caching the result under
    /// `Caches/WatchTranscode/<stem>.m4a` keyed by `WatchTransferMeta.storageStem(for: songId)`.
    /// If a cached file already exists and is at least as new as `source`, it is returned directly
    /// without re-encoding.
    func transcodedFileURL(source: URL, songId: String) async throws -> URL {
        let destination = try cacheDirectory().appendingPathComponent("\(WatchTransferMeta.storageStem(for: songId)).m4a")

        if let cached = existingCacheFile(at: destination, newerThanOrEqualTo: source) {
            return cached
        }

        // Encode into a `.tmp` sibling, then atomically rename into place, so a transcode killed
        // partway through (app suspended mid-transfer, disk full, etc.) can never leave a
        // half-written file at `destination` that a later call mistakes for a complete cache hit.
        let temporaryDestination = destination.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: temporaryDestination)

        try await Self.encode(source: source, to: temporaryDestination)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryDestination, to: destination)
        return destination
    }

    private func existingCacheFile(at destination: URL, newerThanOrEqualTo source: URL) -> URL? {
        guard fileManager.fileExists(atPath: destination.path) else { return nil }
        guard
            let cachedDate = try? fileManager.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date,
            let sourceDate = try? fileManager.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        else { return nil }
        return cachedDate >= sourceDate ? destination : nil
    }

    private func cacheDirectory() throws -> URL {
        let base = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("WatchTranscode", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Runs the `AVAssetReader` → `AVAssetWriter` pump off the calling actor. `destination` must not
    /// already exist (the caller writes to a fresh `.tmp` path and renames it into place).
    private static func encode(source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscodeError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        guard reader.canAdd(readerOutput) else {
            throw TranscodeError.readerFailed("cannot add track output")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: WatchTransferAudioPolicy.targetBitRate,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw TranscodeError.writerFailed("cannot add writer input")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw TranscodeError.readerFailed(reader.error?.localizedDescription ?? "unknown reader error")
        }
        guard writer.startWriting() else {
            throw TranscodeError.writerFailed(writer.error?.localizedDescription ?? "unknown writer error")
        }
        writer.startSession(atSourceTime: .zero)

        try await pump(reader: reader, readerOutput: readerOutput, writer: writer, writerInput: writerInput)
    }

    /// Drives sample buffers from `readerOutput` into `writerInput` until the source is exhausted,
    /// then finishes writing. Resumes exactly once, on either the reader-failure or the
    /// writer-completion path.
    private static func pump(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pumpQueue = DispatchQueue(label: "uk.co.uxmusic.WatchAudioTranscoder.pump")
            writerInput.requestMediaDataWhenReady(on: pumpQueue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                        continue
                    }

                    writerInput.markAsFinished()
                    if reader.status == .failed {
                        reader.cancelReading()
                        continuation.resume(throwing: TranscodeError.readerFailed(reader.error?.localizedDescription ?? "reader failed"))
                        return
                    }
                    writer.finishWriting {
                        if writer.status == .completed {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: TranscodeError.writerFailed(writer.error?.localizedDescription ?? "writer failed"))
                        }
                    }
                    return
                }
            }
        }
    }
}
