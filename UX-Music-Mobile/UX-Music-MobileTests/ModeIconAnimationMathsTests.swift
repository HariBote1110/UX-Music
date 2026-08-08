import SwiftUI
import XCTest
@testable import UX_Music_Mobile

/// Verifies the pure maths behind the Watch shuffle/repeat icons' desktop-style stroke-slide
/// animation (see `ModeIconAnimationMaths`, and `src/renderer/js/ui/player-ui.ts`'s
/// `runShuffleAnimation`/`runLoopAnimation` which this reproduces).
final class ModeIconAnimationMathsTests: XCTestCase {
    // MARK: - approximateLength

    func testApproximateLengthOfStraightLineIsExact() {
        let path = Path { p in
            p.move(to: CGPoint(x: 2, y: 18))
            p.addLine(to: CGPoint(x: 7, y: 18))
        }
        XCTAssertEqual(ModeIconAnimationMaths.approximateLength(of: path), 5, accuracy: 0.0001)
    }

    func testApproximateLengthOfMultiSegmentStraightPathSumsSegments() {
        // M2 18 L7 18 L7 6 — two straight segments, 5 + 12 = 17.
        let path = Path { p in
            p.move(to: CGPoint(x: 2, y: 18))
            p.addLine(to: CGPoint(x: 7, y: 18))
            p.addLine(to: CGPoint(x: 7, y: 6))
        }
        XCTAssertEqual(ModeIconAnimationMaths.approximateLength(of: path), 17, accuracy: 0.0001)
    }

    func testApproximateLengthOfQuarterCircleArcIsWithinTolerance() {
        // A quarter-circle of radius 5, matching the repeat icon's top-left arc geometry
        // (centre (8, 12), radius 5) — expected length = (π · r) / 2.
        let path = Path { p in
            p.addArc(
                center: CGPoint(x: 8, y: 12),
                radius: 5,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        }
        let expected = (CGFloat.pi * 5) / 2
        XCTAssertEqual(ModeIconAnimationMaths.approximateLength(of: path), expected, accuracy: 0.01)
    }

    // MARK: - dashOffset

    func testDashOffsetAtStandardPositionIsZero() {
        XCTAssertEqual(ModeIconAnimationMaths.dashOffset(pos: ModeIconAnimationMaths.posStandard, length: 10), 0, accuracy: 0.0001)
    }

    func testDashOffsetAtExitPositionIsNegative() {
        // dashOf(130, 10) = 10 - 1.3*10 = -3
        XCTAssertEqual(ModeIconAnimationMaths.dashOffset(pos: ModeIconAnimationMaths.posExit, length: 10), -3, accuracy: 0.0001)
    }

    func testDashOffsetAtEnterPositionIsGreaterThanLength() {
        // dashOf(-30, 10) = 10 - (-0.3)*10 = 13
        XCTAssertEqual(ModeIconAnimationMaths.dashOffset(pos: ModeIconAnimationMaths.posEnter, length: 10), 13, accuracy: 0.0001)
    }

    func testDashOffsetAtZeroPositionEqualsFullLength() {
        XCTAssertEqual(ModeIconAnimationMaths.dashOffset(pos: 0, length: 10), 10, accuracy: 0.0001)
    }

    // MARK: - headOffsetX

    func testHeadOffsetXAtExitPositionIsPositiveForUnmirroredHead() {
        // (130 - 100) / 100 * 10 * 1 = 3
        XCTAssertEqual(
            ModeIconAnimationMaths.headOffsetX(pos: ModeIconAnimationMaths.posExit, pathLength: 10, scale: 1, mirrored: false),
            3,
            accuracy: 0.0001
        )
    }

    func testHeadOffsetXAtEnterPositionIsNegativeForUnmirroredHead() {
        // (-30 - 100) / 100 * 10 * 1 = -13
        XCTAssertEqual(
            ModeIconAnimationMaths.headOffsetX(pos: ModeIconAnimationMaths.posEnter, pathLength: 10, scale: 1, mirrored: false),
            -13,
            accuracy: 0.0001
        )
    }

    func testHeadOffsetXSignIsFlippedWhenMirrored() {
        // Repeat's bottom-arc head mirrors the sign relative to its unmirrored counterpart, so its
        // "exit" offset moves left (negative) while the top head's moves right (positive).
        let unmirrored = ModeIconAnimationMaths.headOffsetX(pos: ModeIconAnimationMaths.posExit, pathLength: 10, scale: 1, mirrored: false)
        let mirrored = ModeIconAnimationMaths.headOffsetX(pos: ModeIconAnimationMaths.posExit, pathLength: 10, scale: 1, mirrored: true)
        XCTAssertEqual(mirrored, -unmirrored, accuracy: 0.0001)
    }

    func testHeadOffsetXScalesLinearlyWithScaleFactor() {
        let base = ModeIconAnimationMaths.headOffsetX(pos: ModeIconAnimationMaths.posExit, pathLength: 10, scale: 1, mirrored: false)
        let scaled = ModeIconAnimationMaths.headOffsetX(pos: ModeIconAnimationMaths.posExit, pathLength: 10, scale: 0.5, mirrored: false)
        XCTAssertEqual(scaled, base * 0.5, accuracy: 0.0001)
    }
}
