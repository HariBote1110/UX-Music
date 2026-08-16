import XCTest
@testable import UX_Music_Mobile

/// Guards `Localizable.xcstrings` (iOS app) and `UX-Music-Watch/Localizable.xcstrings` (Watch app)
/// against regressions where a key is added without both an `en` and a `ja` translation, or where a
/// translation is present but left empty. Parses the source `.xcstrings` JSON directly (rather than
/// the compiled `.strings` the running app uses) so this test also catches a key whose *source* file
/// was never given a translation in the first place — a compiled bundle lookup would only reveal that
/// as a silent fallback to the key text, not a hard failure.
final class LocalizationCatalogCompletenessTests: XCTestCase {
    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct StringUnit: Decodable {
                    let state: String
                    let value: String
                }

                let stringUnit: StringUnit
            }

            let localizations: [String: Localization]?
        }

        let strings: [String: Entry]
    }

    private static let requiredLocales = ["en", "ja"]

    /// Walks up from this test file's own path to the repository's `UX-Music-Mobile` project root,
    /// so the source `.xcstrings` files can be read directly regardless of the Xcode-managed working
    /// directory a test run happens to use.
    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.lastPathComponent == "UX-Music-Mobile",
               FileManager.default.fileExists(atPath: url.appendingPathComponent("UX-Music-Mobile.xcodeproj").path) {
                return url
            }
        }
        throw XCTSkip("Could not locate the UX-Music-Mobile project root from \(#filePath)")
    }

    private func assertCatalogComplete(at relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let root = try projectRoot()
        let catalogURL = root.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: catalogURL)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)

        XCTAssertFalse(catalog.strings.isEmpty, "\(relativePath) has no keys", file: file, line: line)

        for (key, entry) in catalog.strings {
            guard let localizations = entry.localizations else {
                XCTFail("\(relativePath): key \"\(key)\" has no localizations at all", file: file, line: line)
                continue
            }
            for locale in Self.requiredLocales {
                guard let localization = localizations[locale] else {
                    XCTFail("\(relativePath): key \"\(key)\" is missing a \"\(locale)\" translation", file: file, line: line)
                    continue
                }
                XCTAssertEqual(
                    localization.stringUnit.state, "translated",
                    "\(relativePath): key \"\(key)\"'s \"\(locale)\" translation is not marked translated",
                    file: file, line: line
                )
                XCTAssertFalse(
                    localization.stringUnit.value.isEmpty,
                    "\(relativePath): key \"\(key)\"'s \"\(locale)\" translation is empty",
                    file: file, line: line
                )
            }
        }
    }

    func testIOSCatalogHasCompleteTranslations() throws {
        try assertCatalogComplete(at: "UX-Music-Mobile/Localizable.xcstrings")
    }

    func testWatchCatalogHasCompleteTranslations() throws {
        try assertCatalogComplete(at: "UX-Music-Watch/Localizable.xcstrings")
    }
}
