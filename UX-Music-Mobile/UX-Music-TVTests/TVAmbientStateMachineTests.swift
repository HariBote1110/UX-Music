import XCTest
@testable import UX_Music_TV

/// TDD (Red): `TVAmbientStateMachine.next` decides ambient/normal presentation purely from
/// playback state + idle duration, with no view/timer dependency (see
/// `progress/tvos-nowplaying.md`).
final class TVAmbientStateMachineTests: XCTestCase {
    func test_staysNormal_whenIdleBelowThreshold() {
        let next = TVAmbientStateMachine.next(
            current: .normal,
            isPlaying: true,
            secondsSinceLastInteraction: TVAmbientStateMachine.idleTimeout - 1
        )
        XCTAssertEqual(next, .normal)
    }

    func test_transitionsToAmbient_whenIdleAtOrAboveThreshold_andPlaying() {
        let next = TVAmbientStateMachine.next(
            current: .normal,
            isPlaying: true,
            secondsSinceLastInteraction: TVAmbientStateMachine.idleTimeout
        )
        XCTAssertEqual(next, .ambient)
    }

    func test_staysNormal_whenIdleLongButNotPlaying() {
        let next = TVAmbientStateMachine.next(
            current: .normal,
            isPlaying: false,
            secondsSinceLastInteraction: TVAmbientStateMachine.idleTimeout + 100
        )
        XCTAssertEqual(next, .normal)
    }

    func test_returnsToNormal_onInteractionEvenIfWasAmbient() {
        let next = TVAmbientStateMachine.next(
            current: .ambient,
            isPlaying: true,
            secondsSinceLastInteraction: 0
        )
        XCTAssertEqual(next, .normal)
    }

    func test_leavesAmbient_whenPlaybackStops() {
        let next = TVAmbientStateMachine.next(
            current: .ambient,
            isPlaying: false,
            secondsSinceLastInteraction: TVAmbientStateMachine.idleTimeout + 5
        )
        XCTAssertEqual(next, .normal)
    }

    func test_staysAmbient_whileStillIdleAndPlaying() {
        let next = TVAmbientStateMachine.next(
            current: .ambient,
            isPlaying: true,
            secondsSinceLastInteraction: TVAmbientStateMachine.idleTimeout + 30
        )
        XCTAssertEqual(next, .ambient)
    }
}
