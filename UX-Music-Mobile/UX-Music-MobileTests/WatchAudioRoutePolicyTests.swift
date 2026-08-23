import XCTest
@testable import UX_Music_Mobile

final class WatchAudioRoutePolicyTests: XCTestCase {

    func testLongFormActivatedTakesPrecedence() {
        XCTAssertEqual(
            WatchAudioRoutePolicy.outcome(longFormActivated: true, speakerActivated: true),
            .longForm
        )
    }

    func testLongFormActivatedAloneIsLongForm() {
        XCTAssertEqual(
            WatchAudioRoutePolicy.outcome(longFormActivated: true, speakerActivated: false),
            .longForm
        )
    }

    func testSpeakerFallbackWhenLongFormFailsButSpeakerSucceeds() {
        XCTAssertEqual(
            WatchAudioRoutePolicy.outcome(longFormActivated: false, speakerActivated: true),
            .speakerFallback
        )
    }

    func testUnavailableWhenBothFail() {
        XCTAssertEqual(
            WatchAudioRoutePolicy.outcome(longFormActivated: false, speakerActivated: false),
            .unavailable
        )
    }
}
