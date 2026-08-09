import Foundation

/// Whether a song's local audio file should be sent to the Apple Watch as-is, or transcoded first
/// (see `WatchAudioTranscoder`).
enum WatchTransferAudioDecision: Equatable {
    case passthrough
    case transcode
}

/// Pure decision logic for whether a downloaded song's audio file should be transcoded to AAC-LC
/// 128 kbps before being transferred to the paired Apple Watch, or sent unmodified.
///
/// Watch playback uses `AVPlayer`, which plays MPEG-4/QuickTime containers (`m4a`/`mp4`/`aac`) and
/// MP3 natively, but cannot play FLAC, WAV, AIFF, CAF, Ogg/Opus, or WMA at all. Separately,
/// WatchConnectivity's effective transfer bandwidth over Bluetooth is roughly 60 KB/s, so a large
/// lossless file (this library is 88% FLAC, mean 34.7 MB/track) takes on the order of 10 minutes to
/// transfer — see `watch_transfer_research/notes/watch-transfer-bottleneck.md`. Transcoding to AAC
/// 128 kbps cuts that by roughly 7–8x.
///
/// No `AVFoundation` import here — kept as pure arithmetic/string logic so it is trivially
/// unit-testable without spinning up a real encoder.
enum WatchTransferAudioPolicy {
    /// Target bit rate `WatchAudioTranscoder` encodes to when `decision` returns `.transcode`.
    static let targetBitRate = 128_000

    /// Formats the Watch's `AVPlayer` can already play, and which are lossy (so re-encoding one
    /// that is already small is pointless extra work and a quality loss rather than a size win).
    private static let passthroughCapableFileTypes: Set<String> = ["mp3", "m4a", "aac", "mp4"]

    /// Bit rate above which a passthrough-capable file is transcoded anyway, because it is
    /// meaningfully bigger than a 128 kbps encode would be.
    private static let passthroughBitRateCeiling = 192_000

    /// - Parameters:
    ///   - fileType: The local file's extension (leading dot and case are normalised away, so
    ///     `.FLAC`/`flac`/`FLAC` are all equivalent).
    ///   - fileSizeBytes: Size of the local audio file on disk.
    ///   - duration: The song's known duration in seconds, used only to estimate the existing bit
    ///     rate of a passthrough-capable file. `<= 0` means "unknown".
    static func decision(fileType: String, fileSizeBytes: Int64, duration: Double) -> WatchTransferAudioDecision {
        let normalised = normalise(fileType)

        guard passthroughCapableFileTypes.contains(normalised) else {
            // FLAC/WAV/AIFF/CAF are lossless and huge; Ogg/Opus/WMA are not merely big — AVPlayer on
            // watchOS cannot play them at all. Either way, always transcode.
            return .transcode
        }

        guard duration > 0 else {
            // Unknown duration: err on the side of not re-encoding a format the Watch can already
            // play, rather than doing pointless work off an unreliable estimate.
            return .passthrough
        }

        let estimatedBitRate = Double(fileSizeBytes) * 8 / duration
        return estimatedBitRate > Double(passthroughBitRateCeiling) ? .transcode : .passthrough
    }

    private static func normalise(_ fileType: String) -> String {
        var value = fileType.lowercased()
        if value.hasPrefix(".") {
            value.removeFirst()
        }
        return value
    }
}
