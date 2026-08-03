import Foundation

struct ServerConfig: Codable, Sendable {
    var host: String
    var port: Int
    /// Other reachable hosts for the same desktop (e.g. from mDNS discovery or a promoted failover
    /// host), tried in order when `host` becomes unreachable. Not part of `Equatable` — see below.
    var fallbackHosts: [String] = []
    /// Device-specific auth token, issued by `POST /v1/pairing/redeem` and required (as
    /// `Authorization: Bearer <token>`) by every LAN API endpoint except `/v1/identity` and
    /// `/v1/pairing/*`. Not part of `Equatable` — see below.
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

}

/// A scanned-but-not-yet-redeemed QR pairing payload (`uxmusic://pair?host=&port=&secret=`).
/// `secret` is a one-time value good for 5 minutes; it must be exchanged for a device token via
/// `POST /v1/pairing/redeem` before it can be used as `ServerConfig.token`.
struct PairingRequest: Equatable, Sendable {
    var host: String
    var port: Int
    var secret: String
    /// All LAN addresses the desktop advertised for itself (from `hosts=`), primary `host` first.
    /// A desktop with several NICs (Wi-Fi/Ethernet/Tailscale) may only be reachable from the phone
    /// on one of these — falls back to `[host]` for older QR codes without `hosts=`.
    var hosts: [String]
}

extension ServerConfig {
    /// Parses `uxmusic://pair?host=&hosts=&port=&secret=` (QR from desktop). The raw token QR/URL
    /// forms are no longer emitted by the desktop — a scanned secret must be redeemed via
    /// `RemoteAPIClient.redeemPairingSecret` to obtain a device token.
    static func pairingRequest(fromPairingURL url: URL) -> PairingRequest? {
        guard (url.scheme ?? "").lowercased() == "uxmusic" else { return nil }
        guard url.host?.lowercased() == "pair" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let host = (items.first { $0.name == "host" }?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = items.first { $0.name == "port" }?.value.flatMap { Int($0) } ?? AppConstants.defaultServerPort
        let secret = (items.first { $0.name == "secret" }?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !secret.isEmpty else { return nil }
        let hostsRaw = items.first { $0.name == "hosts" }?.value ?? ""
        let hosts = hostsRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return PairingRequest(host: host, port: port, secret: secret, hosts: hosts.isEmpty ? [host] : hosts)
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
