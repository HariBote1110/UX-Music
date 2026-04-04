import XCTest
@testable import UX_Music_Mobile

final class GraphicEqualiserConfigurationTests: XCTestCase {
    func testBandCountMatchesFrequencies() {
        XCTAssertEqual(GraphicEqualiserConfiguration.centreFrequenciesHz.count, GraphicEqualiserConfiguration.bandCount)
    }

    func testCentreFrequenciesMatchDesktopBackend() {
        let expected: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000]
        XCTAssertEqual(GraphicEqualiserConfiguration.centreFrequenciesHz, expected)
    }

    func testClampedDecibelRespectsRange() {
        XCTAssertEqual(GraphicEqualiserConfiguration.clampedDecibel(0), 0)
        XCTAssertEqual(GraphicEqualiserConfiguration.clampedDecibel(100), 24)
        XCTAssertEqual(GraphicEqualiserConfiguration.clampedDecibel(-100), -24)
    }

    func testFlatPresetIsAllZero() {
        let bands = GraphicEqualiserConfiguration.bands(forPresetNamed: "Flat")
        XCTAssertEqual(bands?.count, GraphicEqualiserConfiguration.bandCount)
        XCTAssertTrue(bands?.allSatisfy { $0 == 0 } ?? false)
    }

    func testElectronicPresetLength() {
        let bands = GraphicEqualiserConfiguration.bands(forPresetNamed: "Electronic")
        XCTAssertEqual(bands?.count, GraphicEqualiserConfiguration.bandCount)
    }
}
