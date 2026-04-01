import Foundation

/// HTTP client that talks to the UX Music /wear/ endpoint on the local network
final class MusicServerClient {

    private let session: URLSession
    private(set) var baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func updateBaseURL(_ url: URL) {
        baseURL = url
    }

    // MARK: - Ping

    func ping() async throws -> PingResponse {
        let url = baseURL.appendingPathComponent("wear/ping")
        let (data, _) = try await session.data(from: url)
        return try JSONDecoder().decode(PingResponse.self, from: data)
    }

    // MARK: - Song List

    func fetchSongs() async throws -> [Song] {
        let url = baseURL.appendingPathComponent("wear/songs")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ClientError.unexpectedStatus
        }
        return try JSONDecoder().decode([Song].self, from: data)
    }

    // MARK: - File Download

    /// Downloads the audio file for the given song and returns a local URL.
    func downloadFile(songID: String, progressHandler: ((Double) -> Void)? = nil) async throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw ClientError.unexpectedStatus
        }
        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path + "/wear/file"
        components.queryItems = [URLQueryItem(name: "id", value: songID)]
        guard let url = components.url else {
            throw ClientError.unexpectedStatus
        }
        let (localURL, _) = try await session.download(from: url)
        return localURL
    }

    // MARK: - Artwork

    func artworkURL(artworkID: String) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            return baseURL
        }
        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path + "/wear/artwork/"
        components.queryItems = [URLQueryItem(name: "id", value: artworkID)]
        return components.url ?? baseURL
    }
}

// MARK: - Types

extension MusicServerClient {
    struct PingResponse: Decodable {
        let version: String
        let hostname: String
    }

    enum ClientError: LocalizedError {
        case unexpectedStatus
        var errorDescription: String? {
            switch self {
            case .unexpectedStatus: return "Unexpected HTTP response from UX Music server"
            }
        }
    }
}
