import AVFoundation
import XCTest
@testable import UX_Music_Mobile

/// Integration-ish tests: these run a real `AVAssetReader`/`AVAssetWriter` pipeline in the
/// simulator rather than mocking AVFoundation, since the whole point of `WatchAudioTranscoder` is
/// that the produced file is actually small and actually plays back at the right duration.
final class WatchAudioTranscoderTests: XCTestCase {

    /// Writes a short sine-wave WAV (not silence — some encoders special-case silence) to a fresh
    /// temporary file, suitable as a transcode source.
    private func makeTestWAV(duration: Double = 2.0, sampleRate: Double = 44_100) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        let channelData = try XCTUnwrap(buffer.floatChannelData)
        let frequency = 440.0
        for frame in 0..<Int(frameCount) {
            let sampleValue = Float(sin(2.0 * .pi * frequency * Double(frame) / sampleRate)) * 0.2
            for channel in 0..<Int(format.channelCount) {
                channelData[channel][frame] = sampleValue
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testTranscodesToSmallM4aWithCorrectDuration() async throws {
        let source = try makeTestWAV()
        defer { try? FileManager.default.removeItem(at: source) }

        let transcoder = WatchAudioTranscoder()
        let output = try await transcoder.transcodedFileURL(source: source, songId: "test-song-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(output.pathExtension, "m4a")

        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let size = attributes[.size] as? Int ?? Int.max
        XCTAssertLessThan(size, 100_000, "2s @128kbps AAC should be well under 100KB even with container overhead")

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2.0, accuracy: 0.3)
    }

    func testSecondCallReusesCachedFileWithoutReencoding() async throws {
        let source = try makeTestWAV()
        defer { try? FileManager.default.removeItem(at: source) }

        let transcoder = WatchAudioTranscoder()
        let songId = "test-song-cache-\(UUID().uuidString)"

        let firstOutput = try await transcoder.transcodedFileURL(source: source, songId: songId)
        defer { try? FileManager.default.removeItem(at: firstOutput) }
        let firstModDate = try FileManager.default.attributesOfItem(atPath: firstOutput.path)[.modificationDate] as? Date

        // A real re-encode would take at least this long to produce a fresh modification date;
        // waiting past filesystem mtime resolution makes "date unchanged" a meaningful assertion.
        try await Task.sleep(nanoseconds: 1_100_000_000)

        let secondOutput = try await transcoder.transcodedFileURL(source: source, songId: songId)
        let secondModDate = try FileManager.default.attributesOfItem(atPath: secondOutput.path)[.modificationDate] as? Date

        XCTAssertEqual(firstOutput, secondOutput)
        XCTAssertEqual(firstModDate, secondModDate, "second call should reuse the cached file rather than re-encoding")
    }

    // MARK: - TranscodeError.appendFailed
    //
    // `AVAssetWriterInput.append` returning `false` mid-encode (disk full, interrupted session,
    // etc.) is not practical to simulate against a real AVAssetWriter in a unit test, so this pins
    // just the pure error-construction decision the pump loop's append-failure branch relies on:
    // prefer the writer's own error description when available, otherwise fall back to a generic
    // message rather than surfacing `nil`/losing the failure entirely.

    func testAppendFailedUsesWriterErrorDescriptionWhenPresent() {
        XCTAssertEqual(
            WatchAudioTranscoder.TranscodeError.appendFailed(writerErrorDescription: "disk full"),
            .writerFailed("disk full")
        )
    }

    func testAppendFailedFallsBackToGenericMessageWhenWriterErrorIsNil() {
        XCTAssertEqual(
            WatchAudioTranscoder.TranscodeError.appendFailed(writerErrorDescription: nil),
            .writerFailed("append failed")
        )
    }
}
