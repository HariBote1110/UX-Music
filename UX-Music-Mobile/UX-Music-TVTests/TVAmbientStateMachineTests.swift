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

    // MARK: - exitCommand (Menu/Back on Now Playing)

    /// A Menu press while ambient is the "wake up" step of the two-step exit: it must only drop
    /// back to the normal layout, never fall through and dismiss the whole screen in one press
    /// (which would risk the OS interpreting a second rapid Menu as "go to the tvOS home screen").
    func test_exitCommand_fromAmbient_returnsToNormal() {
        XCTAssertEqual(TVAmbientStateMachine.exitCommand(current: .ambient), .returnToNormal)
    }

    /// A Menu press while already normal is the second step: dismiss the Now Playing screen back
    /// to browse.
    func test_exitCommand_fromNormal_dismisses() {
        XCTAssertEqual(TVAmbientStateMachine.exitCommand(current: .normal), .dismissScreen)
    }
}
