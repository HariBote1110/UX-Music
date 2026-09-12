import XCTest
@testable import UX_Music_Mobile

final class WatchAudioRoutePolicyTests: XCTestCase {

    func testSpeakerPreferenceAttemptsSpeakerOnly() {
        XCTAssertEqual(
            WatchAudioRoutePolicy.attempts(preference: .speaker, bluetoothDetected: true),
            [.speaker]
        )
    }

    func testBluetoothPreferenceAttemptsLongFormOnly() {
        XCTAssertEqual(
            WatchAudioRoutePolicy.attempts(preference: .bluetooth, bluetoothDetected: false),
            [.longForm]
        )
    }

    func testAutomaticPreferenceUsesSpeakerWhenBluetoothIsNotDetected() {
        XCTAssertEqual(
            WatchAudioRoutePolicy.attempts(preference: .automatic, bluetoothDetected: false),
            [.speaker]
        )
    }

    func testAutomaticPreferenceTriesLongFormThenSpeakerWhenBluetoothIsDetected() {
        XCTAssertEqual(
            WatchAudioRoutePolicy.attempts(preference: .automatic, bluetoothDetected: true),
            [.longForm, .speaker]
        )
    }

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
