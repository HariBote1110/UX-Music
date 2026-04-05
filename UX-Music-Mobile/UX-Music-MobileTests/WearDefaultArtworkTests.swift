import UIKit
import XCTest
@testable import UX_Music_Mobile

final class WearDefaultArtworkTests: XCTestCase {
    func testBundledDefaultArtworkLoads() {
        let img = WearDefaultArtwork.uiImage()
        XCTAssertNotNil(img)
        XCTAssertGreaterThan(img?.size.width ?? 0, 10)
    }
}
