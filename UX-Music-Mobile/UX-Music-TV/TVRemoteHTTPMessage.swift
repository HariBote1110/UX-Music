import Foundation

/// Minimal HTTP/1.1 request representation for `TVRemoteControlServer`'s socket layer. `parse` is
/// a pure function over raw bytes (no `Network.framework` involved) so the request-line/header/
/// body framing can be unit tested without a live socket.
struct TVRemoteHTTPRequest: Equatable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Parses `buffer` as a complete HTTP/1.1 request. Returns `nil` if the buffer doesn't yet
    /// contain a full request (headers not terminated, or body shorter than `Content-Length`) —
    /// the caller (`TVRemoteControlServer`) treats `nil` as "keep reading more bytes".
    static func parse(_ buffer: Data) -> TVRemoteHTTPRequest? {
        let headerTerminator = Data("\r\n\r\n".utf8)
        guard let headerEndRange = buffer.range(of: headerTerminator) else { return nil }

        let headerData = buffer[buffer.startIndex ..< headerEndRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else { return nil }
        let method = String(requestParts[0])
        let fullPath = String(requestParts[1])
        let path = fullPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? fullPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex ..< colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEndRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let availableBody = buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart)
        guard availableBody >= contentLength else { return nil }
        let body = contentLength > 0
            ? buffer[bodyStart ..< buffer.index(bodyStart, offsetBy: contentLength)]
            : Data()

        return TVRemoteHTTPRequest(method: method, path: path, headers: headers, body: Data(body))
    }
}

/// Pure builder for a raw HTTP/1.1 response's bytes. Kept alongside `TVRemoteHTTPRequest` so both
/// halves of the wire format are unit testable without a socket.
enum TVRemoteHTTPResponse {
    static func json(_ object: [String: Any], status: Int = 200) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return raw(status: status, contentType: "application/json", body: body)
    }

    static func unauthorized() -> Data {
        json(["error": "unauthorized"], status: 401)
    }

    static func notFound() -> Data {
        json(["error": "not found"], status: 404)
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "Unknown"
        }
    }

    private static func raw(status: Int, contentType: String, body: Data) -> Data {
        let headerText = "HTTP/1.1 \(status) \(statusText(status))\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var data = Data(headerText.utf8)
        data.append(body)
        return data
    }
}
