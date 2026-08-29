import XCTest
@testable import UX_Music_Mobile

/// Covers `AdaptiveGridColumns.columnCount(for:)` — the pure maths behind the Library grids'
/// `.adaptive` column spec, tuned so an iPhone portrait width keeps 2 columns (the previous
/// hard-coded behaviour) while an iPad settles on 4-6.
final class AdaptiveGridColumnsTests: XCTestCase {
    func testIPhonePortraitWidthYieldsTwoColumns() {
        // iPhone 15 portrait content width after standard 16pt margins.
        XCTAssertEqual(AdaptiveGridColumns.columnCount(for: 358), 2)
    }

    func testCompactIPhoneWidthYieldsTwoColumns() {
        // iPhone SE portrait content width.
        XCTAssertEqual(AdaptiveGridColumns.columnCount(for: 343), 2)
    }

    func testIPadPortraitWidthYieldsFourToSixColumns() {
        // iPad (10.9") portrait content width.
        let count = AdaptiveGridColumns.columnCount(for: 794)
        XCTAssertTrue((4...6).contains(count), "expected 4-6 columns, got \(count)")
    }

    func testIPadLandscapeWidthYieldsAtLeastFourColumns() {
        // iPad (10.9") landscape content width.
        let count = AdaptiveGridColumns.columnCount(for: 1092)
        XCTAssertGreaterThanOrEqual(count, 4)
    }

    func testZeroOrNegativeWidthYieldsAtLeastOneColumn() {
        XCTAssertEqual(AdaptiveGridColumns.columnCount(for: 0), 1)
        XCTAssertEqual(AdaptiveGridColumns.columnCount(for: -50), 1)
    }

    func testColumnsHelperProducesSingleAdaptiveGridItem() {
        XCTAssertEqual(AdaptiveGridColumns.columns().count, 1)
    }
}
