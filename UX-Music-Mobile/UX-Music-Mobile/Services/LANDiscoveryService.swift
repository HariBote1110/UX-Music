import Combine
import Darwin
import Foundation

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

final class LANDiscoveryService: NSObject, ObservableObject {
    @Published private(set) var peers: [LANDiscoveryPeer] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var isDiscoveryActive = false
    @Published private(set) var errorMessage: String?

    private var browser: NetServiceBrowser?
    private var resolvingServices: [String: NetService] = [:]
    private var scanTimeoutWorkItem: DispatchWorkItem?

    func start(scanTimeout: TimeInterval = 6) {
        cancelScanTimeout()
        errorMessage = nil
        isBrowsing = true
        if browser == nil {
            let next = NetServiceBrowser()
            next.delegate = self
            browser = next
            isDiscoveryActive = true
            next.searchForServices(ofType: AppConstants.syncMDNSServiceType, inDomain: "local.")
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
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        resolvingServices.values.forEach { $0.stop() }
        resolvingServices.removeAll()
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

    private func serviceKey(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }
}

extension LANDiscoveryService: NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async {
            self.isDiscoveryActive = true
            self.isBrowsing = true
            self.errorMessage = nil
        }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        DispatchQueue.main.async {
            self.cancelScanTimeout()
            self.isBrowsing = false
            self.isDiscoveryActive = false
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        DispatchQueue.main.async {
            self.cancelScanTimeout()
            self.isBrowsing = false
            self.isDiscoveryActive = false
            self.errorMessage = "Discovery failed."
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolvingServices[serviceKey(service)] = service
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        resolvingServices.removeValue(forKey: serviceKey(service))
        DispatchQueue.main.async {
            self.peers.removeAll { $0.name == service.name || $0.host == service.hostName }
        }
    }
}

extension LANDiscoveryService: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let txt = LANDiscoveryService.txtDictionary(from: sender.txtRecordData())
        let peer = LANDiscoveryPeer(
            name: sender.name,
            endpointHost: sender.hostName ?? "",
            addressHosts: LANDiscoveryService.hostStrings(from: sender.addresses),
            port: sender.port,
            txt: txt
        )
        DispatchQueue.main.async {
            self.upsert(peer)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolvingServices.removeValue(forKey: serviceKey(sender))
    }

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
