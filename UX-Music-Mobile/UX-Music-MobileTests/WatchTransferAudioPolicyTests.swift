import XCTest
@testable import UX_Music_Mobile

/// Pure decision-logic tests for `WatchTransferAudioPolicy` — see that type's doc comment for the
/// rationale (Watch transfers over WatchConnectivity are bandwidth-bound; this library is 88% FLAC).
final class WatchTransferAudioPolicyTests: XCTestCase {

    // MARK: - Lossless / unsupported formats always transcode, regardless of size

    func testFlacAlwaysTranscodesRegardlessOfSize() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "flac", fileSizeBytes: 1_000, duration: 300), .transcode)
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "flac", fileSizeBytes: 50_000_000, duration: 300), .transcode)
    }

    func testWavAlwaysTranscodes() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "wav", fileSizeBytes: 5_000_000, duration: 180), .transcode)
    }

    func testAiffAlwaysTranscodes() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "aiff", fileSizeBytes: 5_000_000, duration: 180), .transcode)
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "aif", fileSizeBytes: 5_000_000, duration: 180), .transcode)
    }

    func testCafAlwaysTranscodes() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "caf", fileSizeBytes: 5_000_000, duration: 180), .transcode)
    }

    /// AVPlayer on watchOS cannot play these at all — transcoding is not just a size optimisation
    /// here, it is required for playability.
    func testOggAndOpusAndWmaAlwaysTranscode() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "ogg", fileSizeBytes: 3_000_000, duration: 180), .transcode)
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "oga", fileSizeBytes: 3_000_000, duration: 180), .transcode)
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "opus", fileSizeBytes: 3_000_000, duration: 180), .transcode)
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "wma", fileSizeBytes: 3_000_000, duration: 180), .transcode)
    }

    func testUnknownOrEmptyFileTypeAlwaysTranscodes() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "", fileSizeBytes: 3_000_000, duration: 180), .transcode)
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "xyz", fileSizeBytes: 3_000_000, duration: 180), .transcode)
    }

    // MARK: - Lossy passthrough-capable formats

    func testMp3AtAround128kbpsPassesThrough() {
        // 4.8 MB / 300 s ≈ 128 kbps
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "mp3", fileSizeBytes: 4_800_000, duration: 300), .passthrough)
    }

    func testMp3At320kbpsTranscodes() {
        // 12 MB / 300 s ≈ 320 kbps
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "mp3", fileSizeBytes: 12_000_000, duration: 300), .transcode)
    }

    func testM4aAt128kbpsPassesThrough() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "m4a", fileSizeBytes: 4_800_000, duration: 300), .passthrough)
    }

    func testAacAndMp4AreAlsoPassthroughCapable() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "aac", fileSizeBytes: 4_800_000, duration: 300), .passthrough)
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "mp4", fileSizeBytes: 4_800_000, duration: 300), .passthrough)
    }

    // MARK: - Unknown duration (defensive default: avoid a pointless re-encode)

    func testDurationZeroWithMp3PassesThrough() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "mp3", fileSizeBytes: 30_000_000, duration: 0), .passthrough)
    }

    func testDurationZeroWithFlacTranscodes() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "flac", fileSizeBytes: 30_000_000, duration: 0), .transcode)
    }

    func testNegativeDurationIsTreatedAsUnknown() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: "mp3", fileSizeBytes: 30_000_000, duration: -1), .passthrough)
    }

    // MARK: - fileType normalisation

    func testFileTypeNormalisationStripsLeadingDotAndLowercases() {
        XCTAssertEqual(WatchTransferAudioPolicy.decision(fileType: ".FLAC", fileSizeBytes: 1_000, duration: 300), .transcode)
        XCTAssertEqual(
            WatchTransferAudioPolicy.decision(fileType: "MP3", fileSizeBytes: 4_800_000, duration: 300),
            WatchTransferAudioPolicy.decision(fileType: "mp3", fileSizeBytes: 4_800_000, duration: 300)
        )
        XCTAssertEqual(
            WatchTransferAudioPolicy.decision(fileType: ".M4A", fileSizeBytes: 4_800_000, duration: 300),
            .passthrough
        )
    }
}
