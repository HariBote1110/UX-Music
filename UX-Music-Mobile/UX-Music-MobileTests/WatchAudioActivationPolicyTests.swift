import XCTest
@testable import UX_Music_Mobile

/// Tests for the pure "should we re-activate the AVAudioSession?" decision used by
/// `WatchAudioPlayerService.activateAudioSession` — see `WatchAudioActivationPolicy`.
final class WatchAudioActivationPolicyTests: XCTestCase {

    func testSkipsReactivationWhenAlreadyLongFormAndAutomaticBluetoothIsDetected() {
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(
                previouslyActivated: .longForm,
                preference: .automatic,
                bluetoothDetected: true
            ),
            .skip
        )
    }

    func testReactivatesSpeakerWhenPreferenceChangesFromLongFormToSpeaker() {
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(
                previouslyActivated: .longForm,
                preference: .speaker,
                bluetoothDetected: true
            ),
            .attemptSpeaker
        )
    }

    func testRetriesLongFormWhenBluetoothPreferenceFollowsSpeakerFallback() {
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(
                previouslyActivated: .fallback,
                preference: .bluetooth,
                bluetoothDetected: false
            ),
            .attemptLongForm
        )
    }

    func testSkipsReactivationWhenSpeakerPlanMatchesFallback() {
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(
                previouslyActivated: .fallback,
                preference: .automatic,
                bluetoothDetected: false
            ),
            .skip
        )
    }

    func testReactivatesLongFormWhenAutomaticDetectsBluetoothAfterFallback() {
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(
                previouslyActivated: .fallback,
                preference: .automatic,
                bluetoothDetected: true
            ),
            .attemptLongForm
        )
    }

    func testAttemptsSpeakerWhenNothingIsActivatedAndSpeakerIsPreferred() {
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(
                previouslyActivated: nil,
                preference: .speaker,
                bluetoothDetected: true
            ),
            .attemptSpeaker
        )
    }

    func testAttemptsLongFormWhenNothingIsActivatedAndBluetoothIsPreferred() {
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(
                previouslyActivated: nil,
                preference: .bluetooth,
                bluetoothDetected: false
            ),
            .attemptLongForm
        )
    }

    func testAttemptsSpeakerWhenNothingIsActivatedAndAutomaticHasNoBluetooth() {
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(
                previouslyActivated: nil,
                preference: .automatic,
                bluetoothDetected: false
            ),
            .attemptSpeaker
        )
    }
}
