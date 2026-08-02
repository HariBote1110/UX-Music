import UIKit
import XCTest
@testable import UX_Music_Mobile

final class RemoteDefaultArtworkTests: XCTestCase {
    func testBundledDefaultArtworkLoads() {
        let img = RemoteDefaultArtwork.uiImage()
        XCTAssertNotNil(img)
        XCTAssertGreaterThan(img?.size.width ?? 0, 10)
    }
}
