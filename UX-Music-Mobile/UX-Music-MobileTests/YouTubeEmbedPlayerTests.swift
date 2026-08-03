import XCTest
@testable import UX_Music_Mobile

final class YouTubeEmbedPlayerTests: XCTestCase {
    func testBuildEmbedHTMLEmbedsValidVideoID() throws {
        let html = try YouTubeEmbedPlayer.buildEmbedHTML(videoID: "dQw4w9WgXcQ")
        XCTAssertTrue(html.contains("dQw4w9WgXcQ"))
        XCTAssertTrue(html.contains("iframe_api"))
        XCTAssertTrue(html.contains("enablejsapi"))
    }

    func testBuildEmbedHTMLRejectsInvalidVideoID() {
        XCTAssertThrowsError(try YouTubeEmbedPlayer.buildEmbedHTML(videoID: "not an id"))
        XCTAssertThrowsError(try YouTubeEmbedPlayer.buildEmbedHTML(videoID: ""))
        XCTAssertThrowsError(try YouTubeEmbedPlayer.buildEmbedHTML(videoID: "<script>"))
    }

    func testParseBridgeMessageReady() {
        let event = YouTubeEmbedPlayer.parseBridgeMessage(["type": "ready"])
        XCTAssertEqual(event, .ready)
    }

    func testParseBridgeMessageStatePlaying() {
        // YouTube IFrame API player state 1 == playing.
        let event = YouTubeEmbedPlayer.parseBridgeMessage(["type": "state", "state": 1])
        XCTAssertEqual(event, .state(.playing))
    }

    func testParseBridgeMessageStatePaused() {
        let event = YouTubeEmbedPlayer.parseBridgeMessage(["type": "state", "state": 2])
        XCTAssertEqual(event, .state(.paused))
    }

    func testParseBridgeMessageTime() {
        let event = YouTubeEmbedPlayer.parseBridgeMessage(["type": "time", "currentTime": 12.5, "duration": 200.0])
        XCTAssertEqual(event, .time(current: 12.5, duration: 200.0))
    }

    func testParseBridgeMessageError() {
        let event = YouTubeEmbedPlayer.parseBridgeMessage(["type": "error", "code": 153])
        XCTAssertEqual(event, .error(code: 153))
    }

    func testParseBridgeMessageUnknownReturnsNil() {
        XCTAssertNil(YouTubeEmbedPlayer.parseBridgeMessage(["type": "mystery"]))
        XCTAssertNil(YouTubeEmbedPlayer.parseBridgeMessage([:]))
    }

    func testCommandJSONPlayPauseSeek() {
        XCTAssertEqual(YouTubeEmbedPlayer.commandScript(.play), "window.uxYouTubeCommand({cmd:'play'});")
        XCTAssertEqual(YouTubeEmbedPlayer.commandScript(.pause), "window.uxYouTubeCommand({cmd:'pause'});")
        XCTAssertEqual(YouTubeEmbedPlayer.commandScript(.seek(seconds: 42.5)), "window.uxYouTubeCommand({cmd:'seek', seconds:42.5});")
    }
}
