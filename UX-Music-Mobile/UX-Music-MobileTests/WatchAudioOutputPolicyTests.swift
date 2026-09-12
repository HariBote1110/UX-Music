import XCTest
@testable import UX_Music_Mobile

final class WatchAudioOutputPolicyTests: XCTestCase {

    func testPreferenceCasesAreCodableAndStable() throws {
        for preference in WatchAudioOutputPreference.allCases {
            let data = try JSONEncoder().encode(preference)
            XCTAssertEqual(try JSONDecoder().decode(WatchAudioOutputPreference.self, from: data), preference)
        }
    }

    func testPreferenceCasesContainTheThreeOutputModes() {
        XCTAssertEqual(
            WatchAudioOutputPreference.allCases,
            [.automatic, .bluetooth, .speaker]
        )
    }
}
