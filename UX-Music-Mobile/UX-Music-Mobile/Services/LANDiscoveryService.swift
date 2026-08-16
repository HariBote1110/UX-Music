import Combine
import Darwin
import Foundation
import Network

struct LANDiscoveryPeer: Identifiable, Hashable, Sendable {
    let name: String
    let host: String
    let connectionHosts: [String]
    let port: Int
    let txt: [String: String]

    init(name: String, endpointHost: String, addressHosts: [String] = [], port: Int, txt: [String: String]) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.connectionHosts = LANDiscoveryPeer.connectionHosts(endpointHost: endpointHost, addressHosts: addressHosts)
        self.host = self.connectionHosts.first ?? ""
        self.port = port
        self.txt = txt
    }

    var id: String {
        let deviceId = value(forTXTKey: "deviceId")
        if !deviceId.isEmpty { return deviceId }
        return "\(host):\(port)"
    }

    var displayName: String {
        let displayName = value(forTXTKey: "displayName")
        if !displayName.isEmpty { return displayName }
        if !name.isEmpty { return name }
        return host
    }

    var protocolVersion: String {
        value(forTXTKey: "protocolVersion")
    }

    var schemaVersion: String {
        value(forTXTKey: "schemaVersion")
    }

    var roles: [String] {
        value(forTXTKey: "roles")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var supportsRemoteAPI: Bool {
        guard !host.isEmpty, port > 0 else { return false }
        guard !roles.isEmpty else { return true }
        let roleSet = Set(roles.map { $0.lowercased() })
        return roleSet.contains("libraryhost") || roleSet.contains("wearhost")
    }

    var serverConfig: ServerConfig {
        ServerConfig(host: host, port: port)
    }

    var endpointDescription: String {
        "\(host):\(String(port))"
    }

    private func value(forTXTKey key: String) -> String {
        txt.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value ?? ""
    }

    private static func connectionHosts(endpointHost: String, addressHosts: [String]) -> [String] {
        let numericAddresses = addressHosts
            .map(normalisedHost)
            .filter(isIPv4Address)
        let bonjourHost = normalisedHost(endpointHost)
        return uniqueHosts(numericAddresses + [bonjourHost])
    }

    private static func normalisedHost(_ host: String) -> String {
        let trimmed = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if trimmed.lowercased().hasSuffix(".local.local") {
            return String(trimmed.dropLast(".local".count))
        }
        return trimmed
    }

    private static func isIPv4Address(_ host: String) -> Bool {
        var addr = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &addr) == 1 }
    }

    private static func uniqueHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for host in hosts where !host.isEmpty {
            let key = host.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(host)
        }
        return out
    }
}

/// Discovers `_uxmusic-sync._tcp` peers using `Network.framework`'s `NWBrowser`.
///
/// This previously used `NetServiceBrowser`, but on tvOS 26 (verified in the "Apple TV" simulator)
/// `NetServiceBrowser.searchForServices` produced zero mDNS traffic — `log stream` showed no
/// NetService/mDNS activity at all while the host was actively advertising and reachable via
/// `dns-sd`. `NWBrowser` with a `.bonjourWithTXTRecord` descriptor is the modern, actively
/// maintained API for the same job and is confirmed working on both tvOS simulator and iOS.
/// See `progress/tvos-pairing.md` for the investigation notes.
final class LANDiscoveryService: NSObject, ObservableObject {
    @Published private(set) var peers: [LANDiscoveryPeer] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var isDiscoveryActive = false
    @Published private(set) var errorMessage: String?

    private var browser: NWBrowser?
    private var resolvingConnections: [String: NWConnection] = [:]
    private var scanTimeoutWorkItem: DispatchWorkItem?

    func start(scanTimeout: TimeInterval = 6) {
        cancelScanTimeout()
        errorMessage = nil
        isBrowsing = true
        if browser == nil {
            let serviceType = LANDiscoveryService.bonjourType(from: AppConstants.syncMDNSServiceType)
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: nil)
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let next = NWBrowser(for: descriptor, using: parameters)
            next.stateUpdateHandler = { [weak self] state in
                self?.handleBrowserState(state)
            }
            next.browseResultsChangedHandler = { [weak self] results, changes in
                self?.handleResults(results, changes: changes)
            }
            browser = next
            isDiscoveryActive = true
            next.start(queue: .main)
        }
        scheduleScanTimeout(after: scanTimeout)
    }

    func stop() {
        cancelScanTimeout()
        stopBrowsing()
    }

    private func scheduleScanTimeout(after interval: TimeInterval) {
        guard interval > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.finishVisibleScan()
        }
        scanTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
    }

    private func cancelScanTimeout() {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
    }

    private func finishVisibleScan() {
        scanTimeoutWorkItem = nil
        isBrowsing = false
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        resolvingConnections.values.forEach { $0.cancel() }
        resolvingConnections.removeAll()
        isBrowsing = false
        isDiscoveryActive = false
    }

    private func upsert(_ peer: LANDiscoveryPeer) {
        guard peer.supportsRemoteAPI else { return }
        if let index = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[index] = peer
        } else {
            peers.append(peer)
        }
        peers.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            DispatchQueue.main.async {
                self.isDiscoveryActive = true
                self.errorMessage = nil
            }
        case .failed:
            DispatchQueue.main.async {
                self.cancelScanTimeout()
                self.isBrowsing = false
                self.isDiscoveryActive = false
                self.errorMessage = "Discovery failed."
            }
        case .cancelled:
            DispatchQueue.main.async {
                self.isBrowsing = false
                self.isDiscoveryActive = false
            }
        default:
            break
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        for change in changes {
            if case .removed(let result) = change {
                DispatchQueue.main.async {
                    self.peers.removeAll { $0.name == LANDiscoveryService.serviceName(of: result.endpoint) }
                }
            }
        }
        for result in results {
            resolve(result)
        }
    }

    private func resolve(_ result: NWBrowser.Result) {
        let key = LANDiscoveryService.resultKey(result)
        guard resolvingConnections[key] == nil else { return }
        guard let name = LANDiscoveryService.serviceName(of: result.endpoint) else { return }

        let txt: [String: String]
        if case .bonjour(let record) = result.metadata {
            txt = record.dictionary
        } else {
            txt = [:]
        }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        resolvingConnections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let hostPort = LANDiscoveryService.hostAndPort(from: connection.currentPath?.remoteEndpoint)
                connection.cancel()
                self.resolvingConnections.removeValue(forKey: key)
                guard let (host, port) = hostPort else { return }
                let peer = LANDiscoveryPeer(
                    name: name,
                    endpointHost: "\(name).local",
                    addressHosts: [host],
                    port: port,
                    txt: txt
                )
                DispatchQueue.main.async {
                    self.upsert(peer)
                }
            case .failed, .cancelled:
                self.resolvingConnections.removeValue(forKey: key)
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private static func resultKey(_ result: NWBrowser.Result) -> String {
        "\(result.endpoint)"
    }

    private static func serviceName(of endpoint: NWEndpoint) -> String? {
        if case .service(let name, _, _, _) = endpoint {
            return name
        }
        return nil
    }

    /// `NWBrowser`'s Bonjour descriptor wants a bare service type (e.g. `_uxmusic-sync._tcp`), not
    /// the trailing-dot form `NetService`/`NSBonjourServices` use.
    private static func bonjourType(from serviceType: String) -> String {
        serviceType.hasSuffix(".") ? String(serviceType.dropLast()) : serviceType
    }

    /// Resolves an established connection's remote endpoint into a numeric host string + port,
    /// which is how a `.service(...)` Bonjour endpoint's actual reachable address is learned.
    private static func hostAndPort(from endpoint: NWEndpoint?) -> (String, Int)? {
        guard let endpoint, case .hostPort(let host, let port) = endpoint else { return nil }
        return (LANDiscoveryService.hostString(from: host), Int(port.rawValue))
    }

    private static func hostString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            // `IPv4Address`'s own `description` appends a `%interface` scope suffix (e.g.
            // "192.168.1.182%en0") which `inet_pton`/`LANDiscoveryPeer.isIPv4Address` rejects —
            // format the raw 4 bytes ourselves to get a plain dotted-decimal string.
            return address.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let address):
            return "\(address)"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }

    // `TVRemoteDiscoveryService` (iOS-side `_uxmusic-remote._tcp` TV picker) still uses
    // `NetServiceBrowser`/`NetService` and relies on these two parsing helpers. Only this
    // service's own `_uxmusic-sync._tcp` browsing was confirmed inert on tvOS, so that migration
    // is left for its own pass — kept here so it keeps compiling unchanged.
    static func txtDictionary(from data: Data?) -> [String: String] {
        guard let data else { return [:] }
        let raw = NetService.dictionary(fromTXTRecord: data)
        var out: [String: String] = [:]
        for (key, value) in raw {
            out[key] = String(data: value, encoding: .utf8) ?? ""
        }
        return out
    }

    static func hostStrings(from addresses: [Data]?) -> [String] {
        guard let addresses else { return [] }
        var hosts: [String] = []
        for data in addresses {
            let host = data.withUnsafeBytes { rawBuffer -> String? in
                guard let base = rawBuffer.baseAddress else { return nil }
                let sockaddrPointer = base.assumingMemoryBound(to: sockaddr.self)
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    sockaddrPointer,
                    socklen_t(data.count),
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                guard result == 0 else { return nil }
                return String(cString: buffer)
            }
            if let host, !host.isEmpty, !hosts.contains(host) {
                hosts.append(host)
            }
        }
        return hosts
    }
}
