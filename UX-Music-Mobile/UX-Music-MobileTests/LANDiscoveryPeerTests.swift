import Combine
import XCTest
@testable import UX_Music_Mobile

final class LANDiscoveryPeerTests: XCTestCase {
    private var discoveryService: LANDiscoveryService?
    private var discoveryCancellables: Set<AnyCancellable> = []

    override func tearDown() {
        discoveryService?.stop()
        discoveryService = nil
        discoveryCancellables.removeAll()
        super.tearDown()
    }

    func testAppDeclaresLocalNetworkPermissionForWearDiscovery() throws {
        let usage = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        )
        XCTAssertFalse(usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let services = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String]
        )
        XCTAssertTrue(services.contains("_uxmusic-sync._tcp"))
    }

    func testDiscoveryHidesSearchingIndicatorAfterScanTimeout() {
        let service = LANDiscoveryService()
        discoveryService = service
        let stopped = expectation(description: "Discovery scan indicator stops after timeout")
        var didObserveStop = false

        service.$isBrowsing
            .dropFirst()
            .sink { isBrowsing in
                guard !isBrowsing, !didObserveStop else { return }
                didObserveStop = true
                stopped.fulfill()
            }
            .store(in: &discoveryCancellables)

        service.start(scanTimeout: 0.05)
        wait(for: [stopped], timeout: 1)
    }

    func testDiscoveryKeepsListenerActiveAfterScanTimeout() {
        let service = LANDiscoveryService()
        discoveryService = service
        let stopped = expectation(description: "Discovery scan indicator stops after timeout")
        var didObserveStop = false

        service.$isBrowsing
            .dropFirst()
            .sink { isBrowsing in
                guard !isBrowsing, !didObserveStop else { return }
                didObserveStop = true
                stopped.fulfill()
            }
            .store(in: &discoveryCancellables)

        service.start(scanTimeout: 0.05)
        wait(for: [stopped], timeout: 1)

        XCTAssertTrue(service.isDiscoveryActive)
    }

    func testRealDeviceDiscoversUXSyncMDNSPeer() throws {
        #if UX_MUSIC_REAL_DEVICE_DISCOVERY_TEST
        let found = expectation(description: "Discover a Wear-compatible UX Sync peer on the local network")
        var resolvedPeer: LANDiscoveryPeer?
        var discoveryError: String?
        var hasFinished = false
        let service = LANDiscoveryService()
        discoveryService = service

        func finish() {
            guard !hasFinished else { return }
            hasFinished = true
            found.fulfill()
        }

        service.$peers
            .sink { peers in
                guard let peer = peers.first(where: { $0.supportsRemoteAPI }) else { return }
                resolvedPeer = peer
                finish()
            }
            .store(in: &discoveryCancellables)

        service.$errorMessage
            .sink { message in
                guard let message else { return }
                discoveryError = message
                finish()
            }
            .store(in: &discoveryCancellables)

        service.start()
        wait(for: [found], timeout: 10)
        service.stop()

        if let discoveryError {
            XCTFail(discoveryError)
        }

        let peer = try XCTUnwrap(
            resolvedPeer,
            "No Wear-compatible _uxmusic-sync._tcp.local. peer was discovered. Keep UX Music open on the same Wi-Fi network and allow Local Network access for UX Music Mobile."
        )
        XCTAssertTrue(peer.supportsRemoteAPI)
        XCTAssertEqual(peer.port, AppConstants.defaultServerPort)
        #else
        throw XCTSkip("Pass OTHER_SWIFT_FLAGS='$(inherited) -DUX_MUSIC_REAL_DEVICE_DISCOVERY_TEST' to run the real-device LAN discovery probe.")
        #endif
    }

    func testFromTXTBuildsServerConfigForWearHost() {
        let peer = LANDiscoveryPeer(
            name: "YukinoMac-mini",
            endpointHost: "YukinoMac-mini.local",
            addressHosts: [],
            port: 8765,
            txt: [
                "deviceId": "dev-mini",
                "displayName": "Yukino Mac mini",
                "protocolVersion": "0.2",
                "schemaVersion": "2026-06-09",
                "roles": "LibraryHost,PlaybackTarget,Controller",
            ]
        )

        XCTAssertEqual(peer.id, "dev-mini")
        XCTAssertEqual(peer.displayName, "Yukino Mac mini")
        XCTAssertEqual(peer.host, "YukinoMac-mini.local")
        XCTAssertEqual(peer.port, 8765)
        XCTAssertEqual(peer.serverConfig, ServerConfig(host: "YukinoMac-mini.local", port: 8765))
        XCTAssertTrue(peer.supportsRemoteAPI)
    }

    func testFromTXTUsesNumericAddressBeforeBonjourHostname() {
        let peer = LANDiscoveryPeer(
            name: "YukinoMac-mini",
            endpointHost: "YukinoMac-mini.local",
            addressHosts: ["192.168.0.226", "fe80::1"],
            port: 8765,
            txt: ["roles": "LibraryHost"]
        )

        XCTAssertEqual(peer.host, "192.168.0.226")
        XCTAssertEqual(peer.serverConfig, ServerConfig(host: "192.168.0.226", port: 8765))
        XCTAssertEqual(peer.endpointDescription, "192.168.0.226:8765")
    }

    func testFromTXTKeepsAllIPv4ConnectionCandidatesBeforeBonjourHostname() {
        let peer = LANDiscoveryPeer(
            name: "YukinoMac-mini",
            endpointHost: "YukinoMac-mini.local",
            addressHosts: ["192.168.0.226", "fe80::1", "192.168.1.182", "192.168.0.226"],
            port: 8765,
            txt: ["roles": "LibraryHost"]
        )

        XCTAssertEqual(
            peer.connectionHosts,
            ["192.168.0.226", "192.168.1.182", "YukinoMac-mini.local"]
        )
    }

    func testConnectionCandidatesKeepManualHostFirstAndDeduplicateDiscoveredHosts() {
        XCTAssertEqual(
            RemoteConnectionCandidates.hosts(
                manualHost: "192.168.0.226",
                discoveredHosts: ["192.168.0.226", "192.168.1.182", "YukinoMac-mini.local"]
            ),
            ["192.168.0.226", "192.168.1.182", "YukinoMac-mini.local"]
        )
    }

    func testFromTXTFallsBackToServiceNameWhenDisplayNameIsMissing() {
        let peer = LANDiscoveryPeer(
            name: "mainPC",
            endpointHost: "mainpc.local.local.",
            addressHosts: [],
            port: 8765,
            txt: ["roles": "LibraryHost"]
        )

        XCTAssertEqual(peer.displayName, "mainPC")
        XCTAssertEqual(peer.host, "mainpc.local")
        XCTAssertEqual(peer.id, "mainpc.local:8765")
        XCTAssertEqual(peer.endpointDescription, "mainpc.local:8765")
        XCTAssertTrue(peer.supportsRemoteAPI)
    }

    func testFromTXTAllowsRolelessSyncServiceForLegacyAdvertisement() {
        let peer = LANDiscoveryPeer(
            name: "legacy",
            endpointHost: "legacy.local",
            addressHosts: [],
            port: 8765,
            txt: [:]
        )

        XCTAssertTrue(peer.supportsRemoteAPI)
    }

    func testFromTXTRejectsPeerWithoutWearCompatibleRole() {
        let peer = LANDiscoveryPeer(
            name: "Controller",
            endpointHost: "controller.local",
            addressHosts: [],
            port: 8765,
            txt: ["roles": "Controller"]
        )

        XCTAssertFalse(peer.supportsRemoteAPI)
    }
}
