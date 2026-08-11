import XCTest
@testable import UX_Music_Mobile

final class TVRemoteTargetTests: XCTestCase {
    func testMakeSucceedsWithHostPortAndToken() {
        let target = TVRemoteTarget.make(name: "Living Room", host: "192.168.1.20", port: 8766, txt: ["token": "abc123"])
        XCTAssertEqual(target?.host, "192.168.1.20")
        XCTAssertEqual(target?.port, 8766)
        XCTAssertEqual(target?.token, "abc123")
        XCTAssertEqual(target?.baseURLString, "http://192.168.1.20:8766")
        XCTAssertEqual(target?.displayName, "Living Room")
    }

    func testMakeFailsWithoutToken() {
        XCTAssertNil(TVRemoteTarget.make(name: "Living Room", host: "192.168.1.20", port: 8766, txt: [:]))
    }

    func testMakeFailsWithEmptyHostOrNonPositivePort() {
        XCTAssertNil(TVRemoteTarget.make(name: "Living Room", host: "", port: 8766, txt: ["token": "abc"]))
        XCTAssertNil(TVRemoteTarget.make(name: "Living Room", host: "192.168.1.20", port: 0, txt: ["token": "abc"]))
    }

    func testTokenLookupIsCaseInsensitive() {
        let target = TVRemoteTarget.make(name: "Living Room", host: "192.168.1.20", port: 8766, txt: ["Token": "abc123"])
        XCTAssertEqual(target?.token, "abc123")
    }

    func testDisplayNameFallsBackToHostWhenNameEmpty() {
        let target = TVRemoteTarget.make(name: "", host: "192.168.1.20", port: 8766, txt: ["token": "abc"])
        XCTAssertEqual(target?.displayName, "192.168.1.20")
    }
}
