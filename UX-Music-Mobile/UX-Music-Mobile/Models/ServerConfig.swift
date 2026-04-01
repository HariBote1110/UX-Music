import Foundation

struct ServerConfig: Codable, Equatable, Sendable {
    var host: String
    var port: Int

    init(host: String = "", port: Int = AppConstants.defaultServerPort) {
        self.host = host
        self.port = port
    }

    /// Base URL without trailing slash (matches Flutter `ServerConfig.baseUrl`).
    var baseURLString: String {
        let h = host.isEmpty ? "localhost" : host
        return "http://\(h):\(port)"
    }

    var isConfigured: Bool { !host.isEmpty }

    /// Parses `uxmusic://pair?host=&port=` (QR from desktop) or `http(s)://host:port/…`.
    static func fromPairingURL(_ url: URL) -> ServerConfig? {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "uxmusic" {
            guard url.host?.lowercased() == "pair" else { return nil }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let host = (items.first { $0.name == "host" }?.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let port = items.first { $0.name == "port" }?.value.flatMap { Int($0) } ?? AppConstants.defaultServerPort
            guard !host.isEmpty else { return nil }
            return ServerConfig(host: host, port: port)
        }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
            let port = url.port ?? AppConstants.defaultServerPort
            return ServerConfig(host: host, port: port)
        }
        return nil
    }
}
