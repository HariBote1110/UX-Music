import XCTest
import SwiftUI
@testable import UX_Music_Mobile

/// Covers `AccentContrastFallback.isTooLowContrast(saturation:brightness:)` — the pure predicate
/// behind the Now Playing shuffle/repeat active-state tint, which falls back to a fixed
/// high-contrast colour when the artwork-derived accent would be indistinguishable from the dim
/// inactive tint.
final class AccentContrastFallbackTests: XCTestCase {
    func testNearWhiteAccentIsTooLowContrast() {
        XCTAssertTrue(AccentContrastFallback.isTooLowContrast(saturation: 0.05, brightness: 0.98))
    }

    func testPalePastelAccentIsTooLowContrast() {
        XCTAssertTrue(AccentContrastFallback.isTooLowContrast(saturation: 0.2, brightness: 0.95))
    }

    func testVividDarkAccentIsNotTooLowContrast() {
        XCTAssertFalse(AccentContrastFallback.isTooLowContrast(saturation: 0.7, brightness: 0.6))
    }

    /// Bright but strongly saturated (e.g. a vivid neon accent) still reads clearly — brightness
    /// alone should not trigger the fallback.
    func testBrightButSaturatedAccentIsNotTooLowContrast() {
        XCTAssertFalse(AccentContrastFallback.isTooLowContrast(saturation: 0.9, brightness: 0.95))
    }

    /// Dark but desaturated (e.g. near-black) still reads against the dim white tint —
    /// desaturation alone should not trigger the fallback.
    func testDarkDesaturatedAccentIsNotTooLowContrast() {
        XCTAssertFalse(AccentContrastFallback.isTooLowContrast(saturation: 0.1, brightness: 0.2))
    }

    func testResolvedAccentFallsBackForWashedOutColour() {
        let resolved = AccentContrastFallback.resolvedAccent(for: Color(hue: 0.5, saturation: 0.05, brightness: 0.98))
        XCTAssertEqual(resolved, AccentContrastFallback.fixedFallback)
    }

    func testResolvedAccentKeepsVividColour() {
        let vivid = Color(hue: 0.75, saturation: 0.7, brightness: 0.6)
        XCTAssertEqual(AccentContrastFallback.resolvedAccent(for: vivid), vivid)
    }
}
