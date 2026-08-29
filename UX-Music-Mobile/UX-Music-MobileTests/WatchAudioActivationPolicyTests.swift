import XCTest
@testable import UX_Music_Mobile

/// Tests for the pure "should we re-activate the AVAudioSession?" decision used by
/// `WatchAudioPlayerService.activateAudioSession` — see `WatchAudioActivationPolicy`.
final class WatchAudioActivationPolicyTests: XCTestCase {

    func testSkipsReactivationWhenAlreadyLongForm() {
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(previouslyActivated: .longForm),
            .skip
        )
    }

    func testRetriesLongFormWhenPreviouslyFellBackToSpeaker() {
        // A Bluetooth device may have connected since the fallback — always worth retrying
        // `.longFormAudio` rather than assuming the speaker fallback is still the best we can do.
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(previouslyActivated: .fallback),
            .attemptLongForm
        )
    }

    func testAttemptsLongFormWhenNothingActivatedYet() {
        XCTAssertEqual(
            WatchAudioActivationPolicy.plan(previouslyActivated: nil),
            .attemptLongForm
        )
    }
}
