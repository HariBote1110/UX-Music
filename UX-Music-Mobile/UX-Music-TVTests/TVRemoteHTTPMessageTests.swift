import XCTest
@testable import UX_Music_TV

final class TVRemoteHTTPMessageTests: XCTestCase {
    func testParsesGETWithoutBody() {
        let raw = "GET /v1/remote/state?x=1 HTTP/1.1\r\nHost: tv.local\r\nAuthorization: Bearer abc\r\n\r\n"
        let request = TVRemoteHTTPRequest.parse(Data(raw.utf8))
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/v1/remote/state")
        XCTAssertEqual(request?.header("Authorization"), "Bearer abc")
        XCTAssertEqual(request?.body, Data())
    }

    func testParsesPOSTWithBody() {
        let bodyJSON = "{\"action\":\"seek\",\"value\":12.5}"
        let raw = "POST /v1/remote/command HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(bodyJSON.utf8.count)\r\n\r\n\(bodyJSON)"
        let request = TVRemoteHTTPRequest.parse(Data(raw.utf8))
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/v1/remote/command")
        XCTAssertEqual(request.map { String(data: $0.body, encoding: .utf8) ?? "" }, bodyJSON)
    }

    func testReturnsNilWhenHeadersIncomplete() {
        let raw = "GET /v1/identity HTTP/1.1\r\nHost: tv.local\r\n"
        XCTAssertNil(TVRemoteHTTPRequest.parse(Data(raw.utf8)))
    }

    func testReturnsNilWhenBodyShorterThanContentLength() {
        let raw = "POST /v1/remote/command HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"action\":\"toggle\"}"
        XCTAssertNil(TVRemoteHTTPRequest.parse(Data(raw.utf8)))
    }

    func testResponseJSONIncludesStatusLineAndContentLength() {
        let data = TVRemoteHTTPResponse.json(["ok": true])
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json"))
        XCTAssertTrue(text.contains("\"ok\":true") || text.contains("\"ok\" : true"))
    }

    func testUnauthorizedResponseUses401() {
        let data = TVRemoteHTTPResponse.unauthorized()
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
    }
}
