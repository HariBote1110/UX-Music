import Foundation

/// Looks up `key` in `Localizable.xcstrings` (compiled into the host app's bundle, since the test
/// target runs hosted — see `TEST_HOST` in project.pbxproj) for a specific `locale`, bypassing the
/// simulator's current language. Used by tests that pin both the `en` and `ja` translations of a
/// production string directly, so a regression in either language is caught regardless of which
/// locale the test happens to run under.
///
/// Falls back to `String(localized:)` (current-locale lookup) when `locale` is `nil`.
func localizedString(_ key: String, locale: String? = nil) -> String {
    guard let locale else {
        return String(localized: String.LocalizationValue(key))
    }
    guard
        let path = Bundle.main.path(forResource: locale, ofType: "lproj"),
        let bundle = Bundle(path: path)
    else {
        return key
    }
    return bundle.localizedString(forKey: key, value: nil, table: nil)
}
