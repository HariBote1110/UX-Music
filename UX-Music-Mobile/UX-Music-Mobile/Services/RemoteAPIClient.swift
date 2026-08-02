import CFNetwork
import Foundation

// MARK: - LAN session (bypass system HTTP proxy / iCloud Private Relay for RFC1918)

enum RemoteLANProxyKeys {
    static let httpEnable = kCFNetworkProxiesHTTPEnable as String
    static let httpsEnable = "HTTPSEnable"
    static let socksEnable = "SOCKSEnable"
    static let proxyAutoConfigEnable = kCFNetworkProxiesProxyAutoConfigEnable as String
}

/// Dedicated session so `http://192.168.x.x:8765` is not sent through relay (`502 … unreachable through proxy`).
enum RemoteLANURLSession {
    static let shared = URLSession(configuration: makeConfiguration())

    static func makeConfiguration(
        requestTimeout: TimeInterval = 10,
        resourceTimeout: TimeInterval = 45
    ) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.applyRemoteLANProxyBypass()
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.waitsForConnectivity = false
        #if os(iOS)
        config.multipathServiceType = .none
        #endif
        return config
    }
}

private extension URLSessionConfiguration {
    /// The LAN API uses plain `http://` to the desktop and must never be routed through a system relay.
    func applyRemoteLANProxyBypass() {
        connectionProxyDictionary = [
            RemoteLANProxyKeys.httpEnable: 0,
            RemoteLANProxyKeys.httpsEnable: 0,
            RemoteLANProxyKeys.socksEnable: 0,
            RemoteLANProxyKeys.proxyAutoConfigEnable: 0,
        ]
    }
}

/// `{"error":{"code":"...","message":"..."}}` as returned by every LAN API endpoint on failure.
struct RemoteAPIErrorBody: Codable, Equatable, Sendable {
    struct Detail: Codable, Equatable, Sendable {
        var code: String
        var message: String
    }

    var error: Detail
}

enum RemoteAPIError: LocalizedError {
    case httpStatus(Int)
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Download failed (HTTP \(code))."
        case .server(_, let message):
            return message
        }
    }
}

/// JSON from `GET /v1/remote/lyrics?id=…`.
struct RemoteLyricsPayload: Codable, Equatable, Sendable {
    var found: Bool
    var type: String?
    var content: String?
}

/// One desktop playlist row from `GET /v1/remote/playlists`.
struct RemoteDesktopPlaylist: Codable, Equatable, Hashable, Sendable {
    var name: String
    var songIds: [String]
    var pathsNotInLibrary: [String]?
}

/// HTTP client for the UX Music unified LAN API v1 (port 8765 by default).
struct RemoteAPIClient: Sendable {
    private let baseURLString: String
    /// Device auth token sent as `Authorization: Bearer <token>` (or as a `token=` query item for
    /// endpoints that hand a bare URL to something else, e.g. image loaders). Empty means "no token
    /// configured" — requests are sent unauthenticated, matching the pre-pairing desktop or `/v1/identity`.
    private let token: String
    private let session: URLSession

    init(baseURLString: String, token: String = "", session: URLSession = RemoteLANURLSession.shared) {
        self.baseURLString = baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.token = token
        self.session = session
    }

    private func url(path: String) throws -> URL {
        let p = path.hasPrefix("/") ? path : "/\(path)"
        guard let u = URL(string: "\(baseURLString)\(p)") else {
            throw URLError(.badURL)
        }
        return u
    }

    /// Builds a `URLRequest` with the auth header attached (when a token is configured).
    private func authorizedRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func authorizedRequest(path: String) throws -> URLRequest {
        authorizedRequest(url: try url(path: path))
    }

    /// Appends `token=` to a URL's query items (for endpoints handed to code that can't set headers).
    private func withTokenQuery(_ url: URL) -> URL {
        guard !token.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
        return components.url ?? url
    }

    /// Uses `/v1/remote/artwork/?id=…` so IDs stay query-encoded and `URL(string:)` is reliable (path form is brittle on iOS).
    /// Token is added as a query item, not a header, since this string is handed to an image loader.
    func artworkURL(artworkId: String) -> String {
        guard !artworkId.isEmpty else { return "" }
        let encoded = artworkId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artworkId
        var s = "\(baseURLString)/v1/remote/artwork/?id=\(encoded)"
        if !token.isEmpty {
            let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
            s += "&token=\(encodedToken)"
        }
        return s
    }

    /// Decodes the `id` query value from a Remote LAN artwork URL (`/v1/remote/artwork/?id=…`).
    static func artworkId(fromArtworkEndpointURL url: URL) -> String? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard c.path.contains("/v1/remote/artwork") else { return nil }
        return c.queryItems?.first { $0.name == "id" }?.value
    }

    /// Health check against the public identity endpoint. Returns the server hostname on success.
    /// `GET /v1/identity` is exempt from auth, but the token is still sent (harmless) so a stale/invalid
    /// token surfaces nowhere else.
    func ping() async throws -> String {
        let (data, _) = try await session.data(for: authorizedRequest(path: "/v1/identity"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["hostname"] as? String ?? ""
    }

    func fetchSongs() async throws -> [Song] {
        let (data, _) = try await session.data(for: authorizedRequest(path: "/v1/remote/songs"))
        return try JSONDecoder().decode([Song].self, from: data)
    }

    func fetchLoudness() async throws -> [String: Double] {
        let (data, _) = try await session.data(for: authorizedRequest(path: "/v1/remote/loudness"))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var out: [String: Double] = [:]
        for (k, v) in raw {
            if let n = v as? Double { out[k] = n }
            else if let i = v as? Int { out[k] = Double(i) }
            else if let num = v as? NSNumber { out[k] = num.doubleValue }
        }
        return out
    }

    func fetchLyrics(songId: String) async throws -> RemoteLyricsPayload {
        guard var components = URLComponents(string: baseURLString) else {
            throw URLError(.badURL)
        }
        components.path = "/v1/remote/lyrics"
        components.queryItems = [URLQueryItem(name: "id", value: songId)]
        guard let source = components.url else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(for: authorizedRequest(url: source))
        try Self.throwIfNotOK(response, data: data)
        return try JSONDecoder().decode(RemoteLyricsPayload.self, from: data)
    }

    func fetchDesktopPlaylists() async throws -> [RemoteDesktopPlaylist] {
        let (data, response) = try await session.data(for: authorizedRequest(path: "/v1/remote/playlists"))
        try Self.throwIfNotOK(response, data: data)
        return try JSONDecoder().decode([RemoteDesktopPlaylist].self, from: data)
    }

    func fetchState() async throws -> [String: Any] {
        let (data, response) = try await session.data(for: authorizedRequest(path: "/v1/remote/state"))
        try Self.throwIfNotOK(response, data: data)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func sendCommand(action: String, value: Double?) async throws -> Bool {
        var body: [String: Any] = ["action": action]
        if let value { body["value"] = value }
        let json = try JSONSerialization.data(withJSONObject: body)
        var req = try authorizedRequest(path: "/v1/remote/command")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json
        let (data, _) = try await session.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["ok"] as? Bool ?? false
    }

    /// Writes to `destinationURL` (file is replaced if it exists).
    /// Uses `GET /v1/remote/file?id=…` so song keys that are file paths (with `/`) are not mangled in the URL path.
    /// When `preferOriginalAudio` is true, adds `source=original` so the desktop serves the library file; otherwise the transcoded AAC path is used.
    func downloadFile(
        songId: String,
        to destinationURL: URL,
        preferOriginalAudio: Bool = true,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard var components = URLComponents(string: baseURLString) else {
            throw URLError(.badURL)
        }
        components.path = "/v1/remote/file"
        var items = [URLQueryItem(name: "id", value: songId)]
        if preferOriginalAudio {
            items.append(URLQueryItem(name: "source", value: "original"))
        }
        components.queryItems = items
        guard let source = components.url else {
            throw URLError(.badURL)
        }
        try await ProgressDownloadSession.shared.download(
            from: withTokenQuery(source),
            to: destinationURL,
            progress: progress
        )
    }

    /// Fetches `GET /v1/remote/artwork/?id=…` and writes the image bytes (JPEG/PNG/WebP as served by the desktop).
    func downloadArtwork(artworkId: String, to destinationURL: URL) async throws {
        guard var components = URLComponents(string: baseURLString) else {
            throw URLError(.badURL)
        }
        components.path = "/v1/remote/artwork/"
        components.queryItems = [URLQueryItem(name: "id", value: artworkId)]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(for: authorizedRequest(url: withTokenQuery(url)))
        try Self.throwIfNotOK(response, data: data)
        guard !data.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        let fm = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    /// Redeems a one-time QR pairing secret for a device-specific auth token via the public
    /// `POST /v1/pairing/redeem` endpoint. Not tied to any existing token — this is how a token is
    /// first obtained.
    static func redeemPairingSecret(
        baseURLString: String,
        secret: String,
        deviceId: String,
        displayName: String,
        session: URLSession = RemoteLANURLSession.shared
    ) async throws -> (deviceId: String, token: String) {
        let trimmedBase = baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = URL(string: trimmedBase) else {
            throw URLError(.badURL)
        }
        let endpoint = base.appendingPathComponent("v1/pairing/redeem")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "secret": secret,
            "deviceId": deviceId,
            "displayName": displayName,
        ])
        let (data, response) = try await session.data(for: req)
        try throwIfNotOK(response, data: data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty
        else {
            throw URLError(.cannotParseResponse)
        }
        let resolvedDeviceId = obj["deviceId"] as? String ?? deviceId
        return (resolvedDeviceId, token)
    }

    /// Throws `RemoteAPIError` for any non-2xx response, decoding the `{"error":{...}}` body when present.
    private static func throwIfNotOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard !(200 ... 299).contains(http.statusCode) else { return }
        if let body = try? JSONDecoder().decode(RemoteAPIErrorBody.self, from: data) {
            throw RemoteAPIError.server(code: body.error.code, message: body.error.message)
        }
        throw RemoteAPIError.httpStatus(http.statusCode)
    }
}

// MARK: - Progress download

private final class ProgressDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = ProgressDownloadSession()

    private lazy var session: URLSession = {
        let c = RemoteLANURLSession.makeConfiguration(requestTimeout: 30, resourceTimeout: 300)
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    private var tasks: [Int: DownloadState] = [:]
    private let lock = NSLock()

    private struct DownloadState {
        let destination: URL
        let continuation: CheckedContinuation<Void, Error>
        let progress: @Sendable (Int64, Int64) -> Void
    }

    func download(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = session.downloadTask(with: source)
            lock.lock()
            tasks[task.taskIdentifier] = DownloadState(
                destination: destination,
                continuation: cont,
                progress: progress
            )
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let state = tasks[downloadTask.taskIdentifier]
        lock.unlock()
        state?.progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        guard let state = tasks.removeValue(forKey: downloadTask.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            state.continuation.resume(throwing: RemoteAPIError.httpStatus(http.statusCode))
            return
        }

        do {
            let fm = FileManager.default
            let dest = state.destination
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            do {
                try fm.moveItem(at: location, to: dest)
            } catch {
                // Temp file may live on a different volume than the Documents container.
                try fm.copyItem(at: location, to: dest)
                try? fm.removeItem(at: location)
            }
            state.continuation.resume()
        } catch {
            state.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // On success, `didFinishDownloadingTo` already completed the continuation; this is only for failures.
        guard let error else { return }
        lock.lock()
        guard let state = tasks.removeValue(forKey: task.taskIdentifier) else {
            lock.unlock()
            return
        }
        lock.unlock()
        state.continuation.resume(throwing: error)
    }
}
