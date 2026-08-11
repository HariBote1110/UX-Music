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

    // MARK: - IFrame API error code -> localised user-facing message

    func testErrorMessageForInvalidParameter() {
        XCTAssertEqual(YouTubeEmbedPlayer.errorMessage(code: 2), localizedString("Couldn't play the video (invalid parameter)."))
        XCTAssertEqual(localizedString("Couldn't play the video (invalid parameter).", locale: "ja"), "動画を再生できませんでした（不正なパラメータ）。")
        XCTAssertEqual(localizedString("Couldn't play the video (invalid parameter).", locale: "en"), "Couldn't play the video (invalid parameter).")
    }

    func testErrorMessageForHTML5Error() {
        XCTAssertEqual(YouTubeEmbedPlayer.errorMessage(code: 5), localizedString("Couldn't play the video (player error)."))
        XCTAssertEqual(localizedString("Couldn't play the video (player error).", locale: "ja"), "動画を再生できませんでした（プレイヤーエラー）。")
        XCTAssertEqual(localizedString("Couldn't play the video (player error).", locale: "en"), "Couldn't play the video (player error).")
    }

    func testErrorMessageForVideoNotFound() {
        XCTAssertEqual(YouTubeEmbedPlayer.errorMessage(code: 100), localizedString("This video wasn't found (it may have been removed or made private)."))
        XCTAssertEqual(
            localizedString("This video wasn't found (it may have been removed or made private).", locale: "ja"),
            "この動画は見つかりませんでした（削除または非公開の可能性があります）。"
        )
        XCTAssertEqual(
            localizedString("This video wasn't found (it may have been removed or made private).", locale: "en"),
            "This video wasn't found (it may have been removed or made private)."
        )
    }

    func testErrorMessageForEmbedDisallowed() {
        let expected = localizedString("This video's owner has disabled embedded playback. Please watch it in the YouTube app.")
        XCTAssertEqual(YouTubeEmbedPlayer.errorMessage(code: 101), expected)
        XCTAssertEqual(YouTubeEmbedPlayer.errorMessage(code: 150), expected)
        XCTAssertEqual(
            localizedString("This video's owner has disabled embedded playback. Please watch it in the YouTube app.", locale: "ja"),
            "この動画は投稿者により埋め込み再生が許可されていません。YouTubeアプリでご視聴ください。"
        )
        XCTAssertEqual(
            localizedString("This video's owner has disabled embedded playback. Please watch it in the YouTube app.", locale: "en"),
            "This video's owner has disabled embedded playback. Please watch it in the YouTube app."
        )
    }

    func testErrorMessageForLoopbackServerStartFailure() {
        XCTAssertEqual(
            YouTubeEmbedPlayer.errorMessage(code: -1),
            localizedString("Couldn't start the local playback server. Please restart the app and try again.")
        )
        XCTAssertEqual(
            localizedString("Couldn't start the local playback server. Please restart the app and try again.", locale: "ja"),
            "再生用のローカルサーバーを起動できませんでした。アプリを再起動してお試しください。"
        )
        XCTAssertEqual(
            localizedString("Couldn't start the local playback server. Please restart the app and try again.", locale: "en"),
            "Couldn't start the local playback server. Please restart the app and try again."
        )
    }

    func testErrorMessageForUnknownCodeFallsBackToGeneric() {
        let jaFormat = localizedString("An error occurred while playing the video (code: %d).", locale: "ja")
        let enFormat = localizedString("An error occurred while playing the video (code: %d).", locale: "en")
        XCTAssertEqual(jaFormat, "動画の再生中にエラーが発生しました（コード: %d）。")
        XCTAssertEqual(enFormat, "An error occurred while playing the video (code: %d).")

        // `errorMessage(code:)` resolves against the current locale, matching whatever the test
        // host's language happens to be — pin against that same current-locale lookup rather than
        // assuming "en", mirroring `DownloadAudioQualityTests`'s convention.
        let currentFormat = localizedString("An error occurred while playing the video (code: %d).")
        XCTAssertEqual(YouTubeEmbedPlayer.errorMessage(code: 9999), String(format: currentFormat, 9999))
    }

    // MARK: - Loopback host page URL (mirrors `embedHostPageURL` in server/embed_host.go)

    func testLoopbackPageURLBuildsCorrectPathAndQuery() throws {
        let url = try XCTUnwrap(YouTubeEmbedPlayer.loopbackPageURL(port: 54321, videoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:54321/embed?v=dQw4w9WgXcQ")
    }

    func testLoopbackPageURLRejectsInvalidVideoID() {
        XCTAssertNil(YouTubeEmbedPlayer.loopbackPageURL(port: 54321, videoID: "not an id"))
    }

    // MARK: - Embed-restricted fallback (error code -> whether "open in YouTube app" applies)

    func testEmbedFallbackIsOpenInYouTubeAppForEmbedDisallowedCodes() {
        XCTAssertEqual(YouTubeEmbedPlayer.embedFallback(forErrorCode: 101), .openInYouTubeApp)
        XCTAssertEqual(YouTubeEmbedPlayer.embedFallback(forErrorCode: 150), .openInYouTubeApp)
    }

    func testEmbedFallbackIsNoneForOtherErrorCodes() {
        XCTAssertEqual(YouTubeEmbedPlayer.embedFallback(forErrorCode: 2), .none)
        XCTAssertEqual(YouTubeEmbedPlayer.embedFallback(forErrorCode: 5), .none)
        XCTAssertEqual(YouTubeEmbedPlayer.embedFallback(forErrorCode: 100), .none)
        XCTAssertEqual(YouTubeEmbedPlayer.embedFallback(forErrorCode: -1), .none)
        XCTAssertEqual(YouTubeEmbedPlayer.embedFallback(forErrorCode: 9999), .none)
    }

    // MARK: - "Open in YouTube" URLs

    func testYouTubeAppDeepLinkURLForValidVideoID() {
        XCTAssertEqual(
            YouTubeEmbedPlayer.youtubeAppDeepLinkURL(videoID: "dQw4w9WgXcQ")?.absoluteString,
            "youtube://watch?v=dQw4w9WgXcQ"
        )
    }

    func testYouTubeAppDeepLinkURLRejectsInvalidVideoID() {
        XCTAssertNil(YouTubeEmbedPlayer.youtubeAppDeepLinkURL(videoID: "not an id"))
    }

    func testYouTubeWebFallbackURLForValidVideoID() {
        XCTAssertEqual(
            YouTubeEmbedPlayer.youtubeWebFallbackURL(videoID: "dQw4w9WgXcQ")?.absoluteString,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
    }

    func testYouTubeWebFallbackURLRejectsInvalidVideoID() {
        XCTAssertNil(YouTubeEmbedPlayer.youtubeWebFallbackURL(videoID: "not an id"))
    }

    func testURLToOpenPrefersYouTubeAppWhenAvailable() {
        let url = YouTubeEmbedPlayer.urlToOpen(forVideoID: "dQw4w9WgXcQ", youtubeAppIsAvailable: true)
        XCTAssertEqual(url?.absoluteString, "youtube://watch?v=dQw4w9WgXcQ")
    }

    func testURLToOpenFallsBackToWebWhenAppUnavailable() {
        let url = YouTubeEmbedPlayer.urlToOpen(forVideoID: "dQw4w9WgXcQ", youtubeAppIsAvailable: false)
        XCTAssertEqual(url?.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testURLToOpenRejectsInvalidVideoIDRegardlessOfAppAvailability() {
        XCTAssertNil(YouTubeEmbedPlayer.urlToOpen(forVideoID: "not an id", youtubeAppIsAvailable: true))
        XCTAssertNil(YouTubeEmbedPlayer.urlToOpen(forVideoID: "not an id", youtubeAppIsAvailable: false))
    }
}
