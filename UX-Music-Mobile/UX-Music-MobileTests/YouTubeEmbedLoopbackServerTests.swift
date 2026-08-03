import XCTest
@testable import UX_Music_Mobile

/// Exercises `YouTubeEmbedLoopbackServer` against a real loopback socket (no mocking) — this is
/// the same strategy `server/embed_host_test.go` uses on desktop. We start the server, fetch the
/// `/embed?v=<id>` page over real HTTP, and check the response the way `URLSession` (and, in the
/// app, `WKWebView`) would see it.
final class YouTubeEmbedLoopbackServerTests: XCTestCase {
    func testServerServesEmbedPageOverLoopbackHTTP() async throws {
        let server = YouTubeEmbedLoopbackServer()
        let port = try await server.ensureStarted()
        defer { Task { await server.stop() } }

        let url = try XCTUnwrap(YouTubeEmbedPlayer.loopbackPageURL(port: Int(port), videoID: "dQw4w9WgXcQ"))
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")

        let body = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(body.contains("dQw4w9WgXcQ"))
        XCTAssertTrue(body.contains("iframe_api"))
    }

    func testServerRejectsInvalidVideoIDWithBadRequest() async throws {
        let server = YouTubeEmbedLoopbackServer()
        let port = try await server.ensureStarted()
        defer { Task { await server.stop() } }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/embed"
        components.queryItems = [URLQueryItem(name: "v", value: "not-an-id")]
        let url = try XCTUnwrap(components.url)

        let (_, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 400)
    }

    func testEnsureStartedIsIdempotentAndReturnsSamePort() async throws {
        let server = YouTubeEmbedLoopbackServer()
        defer { Task { await server.stop() } }
        let first = try await server.ensureStarted()
        let second = try await server.ensureStarted()
        XCTAssertEqual(first, second)
    }
}
