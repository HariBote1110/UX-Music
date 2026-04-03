import CFNetwork
import Foundation

// MARK: - LAN session (bypass system HTTP proxy / iCloud Private Relay for RFC1918)

/// Dedicated session so `http://192.168.x.x:8765` is not sent through relay (`502 … unreachable through proxy`).
enum WearLANURLSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.applyWearLANProxyBypass()
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.urlCache = .shared
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()
}

private extension URLSessionConfiguration {
    /// iOS exposes only a subset of `CFNetwork` proxy keys; Wear uses plain `http://` to the desktop.
    func applyWearLANProxyBypass() {
        connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
        ]
    }
}

enum WearDownloadError: LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "Download failed (HTTP \(code))."
        }
    }
}

/// JSON from `GET /wear/lyrics?id=…`.
struct WearLyricsPayload: Codable, Equatable, Sendable {
    var found: Bool
    var type: String?
    var content: String?
}

/// One desktop playlist row from `GET /wear/playlists`.
struct WearDesktopPlaylist: Codable, Equatable, Sendable {
    var name: String
    var songIds: [String]
    var pathsNotInLibrary: [String]?
}

/// HTTP client for the UX Music Wear LAN API (port 8765 by default).
struct WearAPIClient: Sendable {
    private let baseURLString: String
    private let session: URLSession

    init(baseURLString: String, session: URLSession = WearLANURLSession.shared) {
        self.baseURLString = baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.session = session
    }

    private func url(path: String) throws -> URL {
        let p = path.hasPrefix("/") ? path : "/\(path)"
        guard let u = URL(string: "\(baseURLString)\(p)") else {
            throw URLError(.badURL)
        }
        return u
    }

    /// Uses `/wear/artwork/?id=…` so IDs stay query-encoded and `URL(string:)` is reliable (path form is brittle on iOS).
    func artworkURL(artworkId: String) -> String {
        guard !artworkId.isEmpty else { return "" }
        let encoded = artworkId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artworkId
        return "\(baseURLString)/wear/artwork/?id=\(encoded)"
    }

    /// Health check. Returns the server hostname on success.
    func ping() async throws -> String {
        let (data, _) = try await session.data(from: try url(path: "/wear/ping"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["hostname"] as? String ?? ""
    }

    func fetchSongs() async throws -> [Song] {
        let (data, _) = try await session.data(from: try url(path: "/wear/songs"))
        return try JSONDecoder().decode([Song].self, from: data)
    }

    func fetchLoudness() async throws -> [String: Double] {
        let (data, _) = try await session.data(from: try url(path: "/wear/loudness"))
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var out: [String: Double] = [:]
        for (k, v) in raw {
            if let n = v as? Double { out[k] = n }
            else if let i = v as? Int { out[k] = Double(i) }
            else if let num = v as? NSNumber { out[k] = num.doubleValue }
        }
        return out
    }

    func fetchLyrics(songId: String) async throws -> WearLyricsPayload {
        guard var components = URLComponents(string: baseURLString) else {
            throw URLError(.badURL)
        }
        components.path = "/wear/lyrics"
        components.queryItems = [URLQueryItem(name: "id", value: songId)]
        guard let source = components.url else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: source)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw WearDownloadError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode(WearLyricsPayload.self, from: data)
    }

    func fetchDesktopPlaylists() async throws -> [WearDesktopPlaylist] {
        let (data, response) = try await session.data(from: try url(path: "/wear/playlists"))
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw WearDownloadError.httpStatus(http.statusCode)
        }
        return try JSONDecoder().decode([WearDesktopPlaylist].self, from: data)
    }

    func fetchState() async throws -> [String: Any] {
        let (data, _) = try await session.data(from: try url(path: "/wear/state"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func sendCommand(action: String, value: Double?) async throws -> Bool {
        var body: [String: Any] = ["action": action]
        if let value { body["value"] = value }
        let json = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: try url(path: "/wear/command"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json
        let (data, _) = try await session.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["ok"] as? Bool ?? false
    }

    /// Writes to `destinationURL` (file is replaced if it exists).
    /// Uses `GET /wear/file?id=…` so song keys that are file paths (with `/`) are not mangled in the URL path.
    /// When `preferOriginalAudio` is true, adds `source=original` so the desktop serves the library file (Wear 2+); otherwise the Watch AAC transcode path is used.
    func downloadFile(
        songId: String,
        to destinationURL: URL,
        preferOriginalAudio: Bool = true,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard var components = URLComponents(string: baseURLString) else {
            throw URLError(.badURL)
        }
        components.path = "/wear/file"
        var items = [URLQueryItem(name: "id", value: songId)]
        if preferOriginalAudio {
            items.append(URLQueryItem(name: "source", value: "original"))
        }
        components.queryItems = items
        guard let source = components.url else {
            throw URLError(.badURL)
        }
        try await ProgressDownloadSession.shared.download(
            from: source,
            to: destinationURL,
            progress: progress
        )
    }

    /// Fetches `GET /wear/artwork/?id=…` and writes the image bytes (JPEG/PNG/WebP as served by the desktop).
    func downloadArtwork(artworkId: String, to destinationURL: URL) async throws {
        guard var components = URLComponents(string: baseURLString) else {
            throw URLError(.badURL)
        }
        components.path = "/wear/artwork/"
        components.queryItems = [URLQueryItem(name: "id", value: artworkId)]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw WearDownloadError.httpStatus(http.statusCode)
        }
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
}

// MARK: - Progress download

private final class ProgressDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = ProgressDownloadSession()

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.applyWearLANProxyBypass()
        c.timeoutIntervalForRequest = 30
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
            state.continuation.resume(throwing: WearDownloadError.httpStatus(http.statusCode))
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
