import Foundation

struct ServerConfig: Codable, Sendable {
    var host: String
    var port: Int
    /// Other reachable hosts for the same desktop (e.g. from mDNS discovery or a promoted failover
    /// host), tried in order when `host` becomes unreachable. Not part of `Equatable` — see below.
    var fallbackHosts: [String] = []
    /// Pairing/auth token required by the desktop's `wearAuthMiddleware` for every endpoint except
    /// `/wear/ping` and `/wear/mobile`. Not part of `Equatable` — see below.
    var token: String = ""

    init(
        host: String = "",
        port: Int = AppConstants.defaultServerPort,
        fallbackHosts: [String] = [],
        token: String = ""
    ) {
        self.host = host
        self.port = port
        self.fallbackHosts = fallbackHosts
        self.token = token
    }

    /// Base URL without trailing slash (matches Flutter `ServerConfig.baseUrl`).
    var baseURLString: String {
        let h = host.isEmpty ? "localhost" : host
        return "http://\(h):\(port)"
    }

    var isConfigured: Bool { !host.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case host, port, fallbackHosts, token
    }

    /// Custom decode so older persisted JSON (no `fallbackHosts`/`token` key) still decodes: the
    /// synthesised `Codable` conformance ignores a property's default value and requires the key
    /// to be present.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        fallbackHosts = try container.decodeIfPresent([String].self, forKey: .fallbackHosts) ?? []
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
    }

    /// Parses `uxmusic://pair?host=&port=&token=` (QR from desktop) or `http(s)://host:port/…?token=`.
    static func fromPairingURL(_ url: URL) -> ServerConfig? {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "uxmusic" {
            guard url.host?.lowercased() == "pair" else { return nil }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let host = (items.first { $0.name == "host" }?.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let port = items.first { $0.name == "port" }?.value.flatMap { Int($0) } ?? AppConstants.defaultServerPort
            let token = items.first { $0.name == "token" }?.value ?? ""
            guard !host.isEmpty else { return nil }
            return ServerConfig(host: host, port: port, token: token)
        }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
            let port = url.port ?? AppConstants.defaultServerPort
            let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "token" }?.value ?? ""
            return ServerConfig(host: host, port: port, token: token)
        }
        return nil
    }
}

extension ServerConfig: Equatable {
    /// Compares only `host`/`port`: `fallbackHosts` and `token` are bookkeeping, not identity —
    /// Settings uses `==` to show a checkmark next to the currently selected discovered peer, and
    /// that must keep matching after a failover promotes a different host into `fallbackHosts`, or
    /// after the token is re-entered/re-paired.
    static func == (lhs: ServerConfig, rhs: ServerConfig) -> Bool {
        lhs.host == rhs.host && lhs.port == rhs.port
    }
}
