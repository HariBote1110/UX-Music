import XCTest
@testable import UX_Music_TV

/// TDD (Red): `TVAmbientPresentation` replaces the old "swap the whole layout for a bottom-anchored
/// text overlay" ambient behaviour, which read on a real Apple TV as **the UI and the artwork simply
/// vanishing** after 30 seconds of no interaction, leaving only the background wash
/// (`progress/tvos-ambient-artwork-retention.md`). Ambient is now a *chrome fade*: artwork, track
/// info and lyrics stay on screen; only the transport controls and progress bar fade out, and the
/// whole content block drifts slowly to keep a static image off the panel for burn-in safety.
final class TVAmbientPresentationTests: XCTestCase {
    // MARK: - Artwork/content must never disappear (the reported defect)

    func test_contentStaysVisible_inAmbient() {
        XCTAssertGreaterThan(TVAmbientPresentation.contentOpacity(ambient: true), 0)
    }

    func test_contentIsFullyOpaque_whenNotAmbient() {
        XCTAssertEqual(TVAmbientPresentation.contentOpacity(ambient: false), 1)
    }

    func test_ambientDimsContentButOnlySlightly() {
        let ambient = TVAmbientPresentation.contentOpacity(ambient: true)
        XCTAssertLessThan(ambient, 1)
        XCTAssertGreaterThanOrEqual(ambient, 0.6)
    }

    // MARK: - Chrome fade

    func test_chromeHiddenInAmbient() {
        XCTAssertEqual(TVAmbientPresentation.chromeOpacity(ambient: true), 0)
    }

    func test_chromeVisibleWhenNormal() {
        XCTAssertEqual(TVAmbientPresentation.chromeOpacity(ambient: false), 1)
    }

    // MARK: - Burn-in drift

    func test_noDrift_whenNotAmbient() {
        let offset = TVAmbientPresentation.driftOffset(ambient: false, secondsSinceAmbientStart: 30)
        XCTAssertEqual(offset, .zero)
    }

    /// Entering ambient must not jump the content — the drift starts from the resting position.
    func test_driftStartsAtRest() {
        let offset = TVAmbientPresentation.driftOffset(ambient: true, secondsSinceAmbientStart: 0)
        XCTAssertEqual(offset.width, 0, accuracy: 0.0001)
        XCTAssertEqual(offset.height, 0, accuracy: 0.0001)
    }

    func test_driftMovesOverTime() {
        let offset = TVAmbientPresentation.driftOffset(
            ambient: true,
            secondsSinceAmbientStart: TVAmbientPresentation.driftPeriod / 4
        )
        XCTAssertGreaterThan(abs(offset.width), 1)
    }

    func test_driftStaysWithinRadius() {
        for step in 0...240 {
            let offset = TVAmbientPresentation.driftOffset(
                ambient: true,
                secondsSinceAmbientStart: TimeInterval(step)
            )
            XCTAssertLessThanOrEqual(abs(offset.width), TVAmbientPresentation.driftRadius + 0.0001)
            XCTAssertLessThanOrEqual(abs(offset.height), TVAmbientPresentation.driftRadius + 0.0001)
        }
    }

    /// A negative elapsed time (clock skew between the `TimelineView` tick and the recorded ambient
    /// entry) must not produce a wilder excursion than the normal range.
    func test_driftHandlesNegativeElapsed() {
        let offset = TVAmbientPresentation.driftOffset(ambient: true, secondsSinceAmbientStart: -10)
        XCTAssertLessThanOrEqual(abs(offset.width), TVAmbientPresentation.driftRadius)
        XCTAssertLessThanOrEqual(abs(offset.height), TVAmbientPresentation.driftRadius)
    }
}
