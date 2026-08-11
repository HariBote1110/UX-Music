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

    /// Pins both catalog localisations for `displayName`'s keys directly (rather than only
    /// checking the device's current locale), so a regression in either language's translation
    /// in `Localizable.xcstrings` is caught regardless of which locale the test runs under.
    func testDisplayNamesAreLocalisedInBothLanguages() {
        XCTAssertEqual(localizedString("Full Quality", locale: "ja"), "フル音質")
        XCTAssertEqual(localizedString("AAC (Small)", locale: "ja"), "AAC (小容量)")
        XCTAssertEqual(localizedString("Full + AAC", locale: "ja"), "フル + AAC")

        XCTAssertEqual(localizedString("Full Quality", locale: "en"), "Full Quality")
        XCTAssertEqual(localizedString("AAC (Small)", locale: "en"), "AAC (Small)")
        XCTAssertEqual(localizedString("Full + AAC", locale: "en"), "Full + AAC")

        XCTAssertEqual(DownloadAudioQuality.original.displayName, localizedString("Full Quality"))
        XCTAssertEqual(DownloadAudioQuality.aac.displayName, localizedString("AAC (Small)"))
        XCTAssertEqual(DownloadAudioQuality.both.displayName, localizedString("Full + AAC"))
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

    // MARK: - DownloadAACBitrate

    func testAACBitrateRawValueRoundTrip() {
        for bitrate in DownloadAACBitrate.allCases {
            XCTAssertEqual(DownloadAACBitrate(rawValue: bitrate.rawValue), bitrate)
        }
    }

    func testAACBitrateAllowedValuesAre128To320() {
        XCTAssertEqual(DownloadAACBitrate.allCases.map(\.rawValue).sorted(), [128, 192, 256, 320])
    }

    func testAACBitrateDefaultIs256() {
        XCTAssertEqual(DownloadAACBitrate.defaultValue, .kbps256)
        XCTAssertEqual(DownloadAACBitrate.defaultValue.rawValue, 256)
    }

    func testAACBitrateRestoredFallsBackToDefaultForInvalidRawValue() {
        XCTAssertEqual(DownloadAACBitrate.restored(fromRawValue: 0), .defaultValue)
        XCTAssertEqual(DownloadAACBitrate.restored(fromRawValue: -1), .defaultValue)
        XCTAssertEqual(DownloadAACBitrate.restored(fromRawValue: 64), .defaultValue)
        XCTAssertEqual(DownloadAACBitrate.restored(fromRawValue: 999), .defaultValue)
    }

    func testAACBitrateRestoredRestoresKnownRawValue() {
        XCTAssertEqual(DownloadAACBitrate.restored(fromRawValue: 128), .kbps128)
        XCTAssertEqual(DownloadAACBitrate.restored(fromRawValue: 192), .kbps192)
        XCTAssertEqual(DownloadAACBitrate.restored(fromRawValue: 256), .kbps256)
        XCTAssertEqual(DownloadAACBitrate.restored(fromRawValue: 320), .kbps320)
    }

    func testAACBitrateDisplayNamesAreLocalisedInBothLanguages() {
        XCTAssertEqual(localizedString("128 kbps", locale: "ja"), "128 kbps")
        XCTAssertEqual(localizedString("192 kbps", locale: "ja"), "192 kbps")
        XCTAssertEqual(localizedString("256 kbps", locale: "ja"), "256 kbps")
        XCTAssertEqual(localizedString("320 kbps", locale: "ja"), "320 kbps")

        XCTAssertEqual(DownloadAACBitrate.kbps128.displayName, localizedString("128 kbps"))
        XCTAssertEqual(DownloadAACBitrate.kbps320.displayName, localizedString("320 kbps"))
    }
}
