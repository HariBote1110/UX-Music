import XCTest
@testable import UX_Music_Mobile

final class EqualiserPresetTests: XCTestCase {
    func testDecodeEmbeddedCatalogContainsFlat() throws {
        let list = try EqualiserPresetCodec.decodeList(jsonString: EqualiserPresetCatalog.embeddedJSON)
        XCTAssertFalse(list.isEmpty)
        let flat = try XCTUnwrap(list.first { $0.id == "flat" })
        XCTAssertEqual(flat.bandGainsDb.count, EqualiserConstants.bandCount)
        XCTAssertEqual(flat.bandGainsDb, Array(repeating: 0, count: EqualiserConstants.bandCount))
    }

    func testPresetNormalisesShortBandArray() throws {
        let json = """
        [{"id":"x","displayName":"X","preampDb":0,"bandGainsDb":[1,2,3]}]
        """
        let list = try EqualiserPresetCodec.decodeList(jsonString: json)
        let one = try XCTUnwrap(list.first)
        XCTAssertEqual(one.bandGainsDb.count, EqualiserConstants.bandCount)
        XCTAssertEqual(one.bandGainsDb[0], 1)
        XCTAssertEqual(one.bandGainsDb[1], 2)
        XCTAssertEqual(one.bandGainsDb[2], 3)
        XCTAssertEqual(one.bandGainsDb[3], 0)
    }

    @MainActor
    func testEqualiserEffectiveCurveDisabledWhenOff() {
        let id = "eq-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: id)!
        defaults.removePersistentDomain(forName: id)
        let store = EqualiserSettingsStore(defaults: defaults)
        store.isEnabled = false
        XCTAssertFalse(store.effectiveCurve().isEnabled)
    }
}
