import XCTest
@testable import UX_Music_Mobile

final class DownloadAudioQualityTests: XCTestCase {
    // MARK: - Raw value round-trip / restore

    func testRawValueRoundTrip() {
        for quality in DownloadAudioQuality.allCases {
            XCTAssertEqual(DownloadAudioQuality(rawValue: quality.rawValue), quality)
        }
    }

    func testRestoredFallsBackToOriginalForUnknownRawValue() {
        XCTAssertEqual(DownloadAudioQuality.restored(fromRawValue: "not-a-real-case"), .original)
    }

    func testRestoredFallsBackToOriginalForMissingRawValue() {
        XCTAssertEqual(DownloadAudioQuality.restored(fromRawValue: nil), .original)
    }

    func testRestoredRestoresKnownRawValue() {
        XCTAssertEqual(DownloadAudioQuality.restored(fromRawValue: "aac"), .aac)
        XCTAssertEqual(DownloadAudioQuality.restored(fromRawValue: "both"), .both)
    }

    func testDisplayNamesAreJapanese() {
        XCTAssertEqual(DownloadAudioQuality.original.displayName, "フル音質")
        XCTAssertEqual(DownloadAudioQuality.aac.displayName, "AAC (小容量)")
        XCTAssertEqual(DownloadAudioQuality.both.displayName, "フル + AAC")
    }

    // MARK: - Request-step derivation

    func testStepsForOriginalIsSingleOriginalStep() {
        XCTAssertEqual(DownloadRequestPlan.steps(for: .original), [DownloadRequestStep(preferOriginalAudio: true)])
    }

    func testStepsForAACIsSingleNonOriginalStep() {
        XCTAssertEqual(DownloadRequestPlan.steps(for: .aac), [DownloadRequestStep(preferOriginalAudio: false)])
    }

    func testStepsForBothIsOriginalThenAAC() {
        XCTAssertEqual(
            DownloadRequestPlan.steps(for: .both),
            [DownloadRequestStep(preferOriginalAudio: true), DownloadRequestStep(preferOriginalAudio: false)]
        )
    }

    // MARK: - AACVariantFinalisePlan

    func testM4aSniffStoresAsVariant() {
        XCTAssertEqual(AACVariantFinalisePlan.plan(sniffedExtension: "m4a", originalAlreadyPresent: false), .storeAsVariant)
        XCTAssertEqual(AACVariantFinalisePlan.plan(sniffedExtension: "m4a", originalAlreadyPresent: true), .storeAsVariant)
    }

    func testNonM4aSniffWithNoOriginalStoresAsOriginal() {
        XCTAssertEqual(AACVariantFinalisePlan.plan(sniffedExtension: "flac", originalAlreadyPresent: false), .storeAsOriginal)
    }

    func testNonM4aSniffWithOriginalPresentDiscards() {
        XCTAssertEqual(AACVariantFinalisePlan.plan(sniffedExtension: "flac", originalAlreadyPresent: true), .discard)
    }
}
