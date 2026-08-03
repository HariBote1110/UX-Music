import Foundation
import Network

/// In-app loopback HTTP host for the YouTube official embed player, mirroring
/// `server/embed_host.go` on desktop.
///
/// `YouTubeEmbedPlayerView` used to load the embed page via
/// `WKWebView.loadHTMLString(_:baseURL:)` with a fake `http://127.0.0.1` `baseURL`. That sets
/// `document.location`/`origin` to a plausible-looking value, but WebKit never actually issues an
/// HTTP request for the page, so YouTube's embed player still treats it as an unusual/empty
/// referer context. For videos with embedding restrictions this reliably surfaces IFrame API
/// error 150/153 on-device, even though the same trick appears to work in the simulator for
/// unrestricted videos. Desktop solved the equivalent problem (Wails serves pages from a
/// `wails://` scheme) with a real loopback HTTP server, so the embed page has a genuine
/// `http://127.0.0.1:<port>` origin. This type is the iOS port of that server: a minimal
/// `NWListener`-backed HTTP/1.1 responder bound to the loopback interface only, serving
/// `GET /embed?v=<id>` and nothing else.
actor YouTubeEmbedLoopbackServer {
    enum ServerError: Error {
        case listenerFailed(String)
    }

    private var listener: NWListener?
    private var port: UInt16?
    private var startTask: Task<UInt16, Error>?

    /// Starts the server on first call and returns its loopback port; subsequent calls return the
    /// already-running server's port without starting a second listener.
    func ensureStarted() async throws -> UInt16 {
        if let port { return port }
        if let startTask {
            return try await startTask.value
        }
        let task = Task<UInt16, Error> { [weak self] in
            try await self?.start() ?? { throw ServerError.listenerFailed("server deallocated") }()
        }
        startTask = task
        let result = try await task.value
        startTask = nil
        return result
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        startTask = nil
    }

    private func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !didResume else { return }
                    didResume = true
                    let boundPort = listener.port?.rawValue ?? 0
                    Task { await self.didStart(port: boundPort) }
                    continuation.resume(returning: boundPort)
                case .failed(let error):
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(throwing: ServerError.listenerFailed(error.debugDescription))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection) }
            }
            listener.start(queue: .main)
        }
    }

    private func didStart(port: UInt16) {
        self.port = port
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, buffer: Data())
    }

    /// Reads until a full HTTP request head (`\r\n\r\n`) is seen. Requests never carry a body in
    /// this server's usage (GET only), so the head is the whole request.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var newBuffer = buffer
            if let data { newBuffer.append(data) }

            if let headerEnd = newBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = newBuffer[..<headerEnd.lowerBound]
                Task { await self.respond(to: head, on: connection) }
                return
            }
            if isComplete || error != nil || data == nil {
                connection.cancel()
                return
            }
            Task { await self.receiveRequest(on: connection, buffer: newBuffer) }
        }
    }

    private func respond(to requestHead: Data, on connection: NWConnection) {
        guard let requestText = String(data: requestHead, encoding: .utf8),
              let requestLine = requestText.components(separatedBy: "\r\n").first
        else {
            send(status: 400, body: "bad request", contentType: "text/plain", on: connection)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            send(status: 400, body: "bad request", contentType: "text/plain", on: connection)
            return
        }

        let target = String(parts[1])
        guard let components = URLComponents(string: target), components.path == "/embed" else {
            send(status: 404, body: "not found", contentType: "text/plain", on: connection)
            return
        }

        let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value ?? ""
        do {
            let html = try YouTubeEmbedPlayer.buildEmbedHTML(videoID: videoID)
            send(status: 200, body: html, contentType: "text/html; charset=utf-8", on: connection)
        } catch {
            send(status: 400, body: "invalid video id", contentType: "text/plain", on: connection)
        }
    }

    private func send(status: Int, body: String, contentType: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let statusText = Self.statusText(for: status)
        let head = "HTTP/1.1 \(status) \(statusText)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        var responseData = Data(head.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default: return "Error"
        }
    }
}
