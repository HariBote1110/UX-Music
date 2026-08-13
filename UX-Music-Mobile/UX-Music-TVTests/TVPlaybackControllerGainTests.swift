import XCTest
@testable import UX_Music_TV

/// `TVPlaybackController.linearLoudnessGain` is a pure re-derivation of
/// `MusicPlayerService.applyLoudnessGain()`'s formula (`MusicPlayerService`'s engine/EQ are fully
/// private, so there is nothing to call directly — see `TVPlaybackController`'s doc comment and
/// `progress/tvos-playback.md`'s "EQ/LUFSのルーティング判断" 追記). Covered here so a future
/// divergence between the two formulas (e.g. someone tweaking one but not the other) is caught.
final class TVPlaybackControllerGainTests: XCTestCase {
    func testReturnsUnityGainWhenNormaliseDisabled() {
        let gain = TVPlaybackController.linearLoudnessGain(lufs: -8, targetLoudness: -18, normaliseEnabled: false)
        XCTAssertEqual(gain, 1)
    }

    func testReturnsUnityGainWhenLufsMissing() {
        let gain = TVPlaybackController.linearLoudnessGain(lufs: nil, targetLoudness: -18, normaliseEnabled: true)
        XCTAssertEqual(gain, 1)
    }

    func testAppliesPositiveGainForQuieterThanTargetTrack() {
        // Track measured quieter than target (-24 LUFS vs -18 target) needs gain > 1.
        let gain = TVPlaybackController.linearLoudnessGain(lufs: -24, targetLoudness: -18, normaliseEnabled: true)
        XCTAssertEqual(gain, Float(pow(10, 6.0 / 20)), accuracy: 0.0001)
        XCTAssertGreaterThan(gain, 1)
    }

    func testAppliesAttenuationForLouderThanTargetTrack() {
        // Track measured louder than target (-8 LUFS vs -18 target) needs gain < 1.
        let gain = TVPlaybackController.linearLoudnessGain(lufs: -8, targetLoudness: -18, normaliseEnabled: true)
        XCTAssertEqual(gain, Float(pow(10, -10.0 / 20)), accuracy: 0.0001)
        XCTAssertLessThan(gain, 1)
    }

    func testClampsExtremeGainToZeroToFourRange() {
        let extremeBoost = TVPlaybackController.linearLoudnessGain(lufs: -60, targetLoudness: -18, normaliseEnabled: true)
        XCTAssertEqual(extremeBoost, 4)

        let extremeCut = TVPlaybackController.linearLoudnessGain(lufs: 40, targetLoudness: -18, normaliseEnabled: true)
        XCTAssertGreaterThanOrEqual(extremeCut, 0)
        XCTAssertLessThan(extremeCut, 0.01)
    }
}
