import AVFoundation
import Foundation

/// Transcodes a local audio file to AAC-LC 128 kbps stereo 44.1 kHz in an `.m4a` container, for
/// transfer to the Apple Watch when `WatchTransferAudioPolicy.decision(...)` says `.transcode`
/// (see that type for the rationale).
struct WatchAudioTranscoder {
    enum TranscodeError: LocalizedError, Equatable {
        case noAudioTrack
        case readerFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return String(localized: "No audio track was found")
            case .readerFailed(let reason):
                return String(format: String(localized: "Reading failed: %@"), reason)
            case .writerFailed(let reason):
                return String(format: String(localized: "Writing failed: %@"), reason)
            }
        }

        /// Error to surface when `AVAssetWriterInput.append` returns `false` mid-encode (disk full,
        /// an interrupted `AVAudioSession`, etc.). `AVAssetWriter.error` may not be populated the
        /// instant `append` fails, so this falls back to a generic message rather than losing the
        /// failure entirely.
        static func appendFailed(writerErrorDescription: String?) -> Self {
            .writerFailed(writerErrorDescription ?? "append failed")
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
    /// then finishes writing. Resumes exactly once, on the reader-failure, append-failure, or
    /// writer-completion path.
    ///
    /// `resumeOnce` guards against a double-resume (a `CheckedContinuation` misuse that traps): all
    /// call sites run serially on `pumpQueue` (the queue passed to `requestMediaDataWhenReady`), so
    /// the `didResume` flag needs no separate locking.
    private static func pump(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let pumpQueue = DispatchQueue(label: "uk.co.uxmusic.WatchAudioTranscoder.pump")
            var didResume = false
            func resumeOnce(throwing error: Error?) {
                guard !didResume else { return }
                didResume = true
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            writerInput.requestMediaDataWhenReady(on: pumpQueue) {
                while writerInput.isReadyForMoreMediaData {
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        if reader.status == .failed {
                            reader.cancelReading()
                            resumeOnce(throwing: TranscodeError.readerFailed(reader.error?.localizedDescription ?? "reader failed"))
                            return
                        }
                        writer.finishWriting {
                            if writer.status == .completed {
                                resumeOnce(throwing: nil)
                            } else {
                                resumeOnce(throwing: TranscodeError.writerFailed(writer.error?.localizedDescription ?? "writer failed"))
                            }
                        }
                        return
                    }

                    guard writerInput.append(sampleBuffer) else {
                        // `append` returning false means the writer has failed mid-encode (disk
                        // full, an interrupted session, etc.). Left unhandled, `isReadyForMoreMediaData`
                        // typically goes false without the ready-callback ever firing again, so the
                        // continuation would never resume — the caller's `Task` in
                        // `WatchTransferBridge.performTransfer` would hang forever with the queue
                        // item stuck in `.preparing` and no fallback transfer of the original file.
                        reader.cancelReading()
                        writerInput.markAsFinished()
                        resumeOnce(throwing: TranscodeError.appendFailed(writerErrorDescription: writer.error?.localizedDescription))
                        return
                    }
                }
            }
        }
    }
}
