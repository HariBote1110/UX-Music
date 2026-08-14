import UIKit
import XCTest
@testable import UX_Music_Mobile

final class SidecarDirectiveTests: XCTestCase {

    // MARK: - SidecarOrientationPolicy

    func testMaskIsLandscapeWhenSidecarPresented() {
        XCTAssertEqual(SidecarOrientationPolicy.mask(sidecarPresented: true), .landscape)
    }

    func testMaskIsAllWhenSidecarNotPresented() {
        XCTAssertEqual(SidecarOrientationPolicy.mask(sidecarPresented: false), .all)
    }

    // MARK: - SidecarChromeVisibilityPolicy

    func testChromeVisibleImmediatelyAfterInteraction() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(SidecarChromeVisibilityPolicy.isVisible(lastInteraction: now, now: now))
    }

    func testChromeVisibleJustBeforeIdleThreshold() {
        let last = Date(timeIntervalSince1970: 1000)
        let now = last.addingTimeInterval(4.9)
        XCTAssertTrue(SidecarChromeVisibilityPolicy.isVisible(lastInteraction: last, now: now))
    }

    func testChromeHiddenAtIdleThreshold() {
        let last = Date(timeIntervalSince1970: 1000)
        let now = last.addingTimeInterval(5)
        XCTAssertFalse(SidecarChromeVisibilityPolicy.isVisible(lastInteraction: last, now: now))
    }

    func testChromeHiddenWellPastIdleThreshold() {
        let last = Date(timeIntervalSince1970: 1000)
        let now = last.addingTimeInterval(60)
        XCTAssertFalse(SidecarChromeVisibilityPolicy.isVisible(lastInteraction: last, now: now))
    }

    func testChromeVisibleAgainWithCustomThreshold() {
        let last = Date(timeIntervalSince1970: 1000)
        let now = last.addingTimeInterval(2)
        XCTAssertFalse(SidecarChromeVisibilityPolicy.isVisible(lastInteraction: last, now: now, idleThreshold: 1))
    }

    // MARK: - SidecarDirective.parse

    func testParseActiveWithSongIdAndArtworkId() {
        let state: [String: Any] = [
            "sidecar": ["active": true],
            "songId": "song-1",
            "artworkId": "artwork-1",
        ]
        let directive = SidecarDirective.parse(from: state)
        XCTAssertEqual(directive, SidecarDirective(active: true, songId: "song-1", artworkId: "artwork-1"))
    }

    func testParseActiveWithoutSongIdOrArtworkId() {
        let state: [String: Any] = ["sidecar": ["active": true]]
        let directive = SidecarDirective.parse(from: state)
        XCTAssertEqual(directive, SidecarDirective(active: true, songId: nil, artworkId: nil))
    }

    func testParseActiveWithEmptyStringIdsTreatsThemAsAbsent() {
        let state: [String: Any] = [
            "sidecar": ["active": true],
            "songId": "",
            "artworkId": "",
        ]
        let directive = SidecarDirective.parse(from: state)
        XCTAssertEqual(directive, SidecarDirective(active: true, songId: nil, artworkId: nil))
    }

    func testParseExplicitlyInactive() {
        let state: [String: Any] = ["sidecar": ["active": false], "songId": "song-1"]
        XCTAssertEqual(SidecarDirective.parse(from: state), .inactive)
    }

    func testParseMissingSidecarKey() {
        let state: [String: Any] = ["title": "Some Song"]
        XCTAssertEqual(SidecarDirective.parse(from: state), .inactive)
    }

    func testParseSidecarNotADictionary() {
        let state: [String: Any] = ["sidecar": "not-a-dict"]
        XCTAssertEqual(SidecarDirective.parse(from: state), .inactive)
    }

    func testParseActiveNotABool() {
        let state: [String: Any] = ["sidecar": ["active": "yes"]]
        XCTAssertEqual(SidecarDirective.parse(from: state), .inactive)
    }

    func testParseMissingActiveKey() {
        let state: [String: Any] = ["sidecar": [:]]
        XCTAssertEqual(SidecarDirective.parse(from: state), .inactive)
    }

    func testParseEmptyState() {
        XCTAssertEqual(SidecarDirective.parse(from: [:]), .inactive)
    }

    // MARK: - SidecarProgressInterpolation

    func testInterpolationAdvancesWhilePlaying() {
        let start = Date(timeIntervalSince1970: 1000)
        let now = start.addingTimeInterval(2.5)
        let result = SidecarProgressInterpolation.interpolatedPosition(
            position: 10, timestamp: start, playing: true, now: now, duration: 200
        )
        XCTAssertEqual(result, 12.5, accuracy: 0.001)
    }

    func testInterpolationHoldsStillWhilePaused() {
        let start = Date(timeIntervalSince1970: 1000)
        let now = start.addingTimeInterval(5)
        let result = SidecarProgressInterpolation.interpolatedPosition(
            position: 10, timestamp: start, playing: false, now: now, duration: 200
        )
        XCTAssertEqual(result, 10, accuracy: 0.001)
    }

    func testInterpolationClampsToDuration() {
        let start = Date(timeIntervalSince1970: 1000)
        let now = start.addingTimeInterval(500)
        let result = SidecarProgressInterpolation.interpolatedPosition(
            position: 10, timestamp: start, playing: true, now: now, duration: 200
        )
        XCTAssertEqual(result, 200, accuracy: 0.001)
    }

    func testInterpolationClampsToZeroWhenNowPrecedesTimestamp() {
        let start = Date(timeIntervalSince1970: 1000)
        let now = start.addingTimeInterval(-5)
        let result = SidecarProgressInterpolation.interpolatedPosition(
            position: 10, timestamp: start, playing: true, now: now, duration: 200
        )
        XCTAssertEqual(result, 10, accuracy: 0.001)
    }

    func testInterpolationWithoutDurationStillClampsToZero() {
        let start = Date(timeIntervalSince1970: 1000)
        let now = start.addingTimeInterval(-100)
        let result = SidecarProgressInterpolation.interpolatedPosition(
            position: 0, timestamp: start, playing: true, now: now, duration: 0
        )
        XCTAssertEqual(result, 0, accuracy: 0.001)
    }

    // MARK: - SidecarPresentationPolicy

    func testShouldPresentWhenActiveAndNotDismissed() {
        XCTAssertTrue(SidecarPresentationPolicy.shouldPresent(active: true, locallyDismissed: false))
    }

    func testShouldNotPresentWhenInactive() {
        XCTAssertFalse(SidecarPresentationPolicy.shouldPresent(active: false, locallyDismissed: false))
    }

    func testShouldNotPresentWhenLocallyDismissed() {
        XCTAssertFalse(SidecarPresentationPolicy.shouldPresent(active: true, locallyDismissed: true))
    }

    func testShouldClearDismissalOnFalseToTrueTransition() {
        XCTAssertTrue(SidecarPresentationPolicy.shouldClearDismissal(previousActive: false, newActive: true))
    }

    func testShouldNotClearDismissalWhenAlreadyActive() {
        XCTAssertFalse(SidecarPresentationPolicy.shouldClearDismissal(previousActive: true, newActive: true))
    }

    func testShouldNotClearDismissalOnTrueToFalseTransition() {
        XCTAssertFalse(SidecarPresentationPolicy.shouldClearDismissal(previousActive: true, newActive: false))
    }
}
