import XCTest
@testable import UX_Music_TV

final class TVSongStreamPlaybackReducerTests: XCTestCase {
    func testStartTransitionsToLoading() {
        XCTAssertEqual(TVSongStreamPlaybackReducer.reduce(.idle, event: .start), .loading)
    }

    func testDidStartRenderingTransitionsLoadingToStreaming() {
        XCTAssertEqual(TVSongStreamPlaybackReducer.reduce(.loading, event: .didStartRendering), .streaming)
    }

    func testDidStartRenderingIgnoredWhenNotLoading() {
        // A stray callback after failure/reset must not resurrect playback state.
        XCTAssertEqual(
            TVSongStreamPlaybackReducer.reduce(.failed(reason: "x"), event: .didStartRendering),
            .failed(reason: "x")
        )
        XCTAssertEqual(TVSongStreamPlaybackReducer.reduce(.idle, event: .didStartRendering), .idle)
    }

    func testDidReachEndOfStreamTransitionsToFinished() {
        XCTAssertEqual(TVSongStreamPlaybackReducer.reduce(.streaming, event: .didReachEndOfStream), .finished)
    }

    func testFailTransitionsToFailedWithReason() {
        XCTAssertEqual(
            TVSongStreamPlaybackReducer.reduce(.streaming, event: .fail(reason: "network")),
            .failed(reason: "network")
        )
    }

    func testResetTransitionsToIdleFromAnyState() {
        XCTAssertEqual(TVSongStreamPlaybackReducer.reduce(.streaming, event: .reset), .idle)
        XCTAssertEqual(TVSongStreamPlaybackReducer.reduce(.failed(reason: "x"), event: .reset), .idle)
        XCTAssertEqual(TVSongStreamPlaybackReducer.reduce(.finished, event: .reset), .idle)
    }

    func testIsLoadingOnlyTrueInLoadingState() {
        XCTAssertTrue(TVSongStreamPlaybackReducer.isLoading(.loading))
        XCTAssertFalse(TVSongStreamPlaybackReducer.isLoading(.idle))
        XCTAssertFalse(TVSongStreamPlaybackReducer.isLoading(.streaming))
        XCTAssertFalse(TVSongStreamPlaybackReducer.isLoading(.finished))
        XCTAssertFalse(TVSongStreamPlaybackReducer.isLoading(.failed(reason: "x")))
    }

    // MARK: - TVSongPlaybackPlan

    func testShouldStreamOnlyOnCacheMiss() {
        XCTAssertFalse(TVSongPlaybackPlan.shouldStream(cacheHit: true))
        XCTAssertTrue(TVSongPlaybackPlan.shouldStream(cacheHit: false))
    }
}
