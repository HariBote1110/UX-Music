import Foundation

/// One TV discovered on `_uxmusic-remote._tcp` (Phase 3-1 Connect-style target picker,
/// `markdown/appletv-servermode-plan.md` §3-1). `token` comes straight from the TXT record —
/// `TVRemoteControlServer` advertises the same control token it validates requests against (an
/// independent token the TV mints for itself via `TVControlTokenStore`, NOT the host pairing
/// token — see `progress/tvos-connect.md` 2026-08-12 追記 for the security rationale), so no
/// extra handshake is needed before this iOS app can issue commands against it.
struct TVRemoteTarget: Identifiable, Hashable, Sendable {
    let name: String
    let host: String
    let port: Int
    let token: String

    var id: String { "\(host):\(port)" }
    var displayName: String { name.isEmpty ? host : name }

    /// Builds the `RemoteAPIClient` base URL string, matching the `"http://\(host):\(port)"`
    /// convention already used for the Host (`TVAppModel`/`AppModel`) — the TV receiver speaks
    /// plain HTTP on the LAN just like the desktop does.
    var baseURLString: String { "http://\(host):\(port)" }

    /// Pure TXT-record parse, split out from the `NetService` delegate glue below so the "is this
    /// service actually usable" decision (needs a non-empty host, positive port, and a token) is
    /// unit-testable without touching Bonjour.
    static func make(name: String, host: String, port: Int, txt: [String: String]) -> TVRemoteTarget? {
        guard !host.isEmpty, port > 0 else { return nil }
        let token = txt.first { $0.key.caseInsensitiveCompare("token") == .orderedSame }?.value ?? ""
        guard !token.isEmpty else { return nil }
        return TVRemoteTarget(name: name, host: host, port: port, token: token)
    }
}

/// Discovers `_uxmusic-remote._tcp` peers (TVs running `TVRemoteControlServer`) via the same
/// `NetServiceBrowser`/`NetService` pair `LANDiscoveryService` uses for `_uxmusic-sync._tcp` — not
/// reusing that type directly since its `LANDiscoveryPeer.supportsRemoteAPI` gate is tied to Sync
/// host roles (`libraryHost`/`wearHost`), which a TV's `roles` never carries.
final class TVRemoteDiscoveryService: NSObject, ObservableObject {
    @Published private(set) var targets: [TVRemoteTarget] = []

    private var browser: NetServiceBrowser?
    private var resolvingServices: [String: NetService] = [:]

    func start() {
        guard browser == nil else { return }
        let next = NetServiceBrowser()
        next.delegate = self
        browser = next
        next.searchForServices(ofType: AppConstants.tvRemoteMDNSServiceType, inDomain: "local.")
    }

    func stop() {
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        resolvingServices.values.forEach { $0.stop() }
        resolvingServices.removeAll()
        targets = []
    }

    private func serviceKey(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private func upsert(_ target: TVRemoteTarget) {
        if let index = targets.firstIndex(where: { $0.id == target.id }) {
            targets[index] = target
        } else {
            targets.append(target)
        }
        targets.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

extension TVRemoteDiscoveryService: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices[serviceKey(service)] = service
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        resolvingServices.removeValue(forKey: serviceKey(service))
        DispatchQueue.main.async {
            self.targets.removeAll { $0.name == service.name }
        }
    }
}

extension TVRemoteDiscoveryService: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let txt = LANDiscoveryService.txtDictionary(from: sender.txtRecordData())
        let hosts = LANDiscoveryService.hostStrings(from: sender.addresses)
        guard let host = hosts.first ?? sender.hostName else { return }
        guard let target = TVRemoteTarget.make(name: sender.name, host: host, port: sender.port, txt: txt) else { return }
        DispatchQueue.main.async {
            self.upsert(target)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolvingServices.removeValue(forKey: serviceKey(sender))
    }
}
