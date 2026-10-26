import AVFoundation
import SwiftUI
import XCTest
@testable import UX_Music_Mobile

final class RemoteConnectionResolverTests: XCTestCase {
    func testResolve_returnsFastSuccessWithoutWaitingForSlowFailureAhead() async {
        let candidates = [
            ServerConfig(host: "10.0.0.1", port: 8765),
            ServerConfig(host: "10.0.0.2", port: 8765),
        ]
        let start = Date()
        let result = await RemoteConnectionResolver.resolve(candidates: candidates) { config in
            if config.host == "10.0.0.1" {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw URLError(.cannotConnectToHost)
            }
            return "desk"
        }
        XCTAssertEqual(result?.config.host, "10.0.0.2")
        XCTAssertEqual(result?.serverName, "desk")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testResolve_returnsOnlySuccessThatAnswersLate() async {
        let candidates = [
            ServerConfig(host: "10.0.0.1", port: 8765),
            ServerConfig(host: "10.0.0.2", port: 8765),
            ServerConfig(host: "10.0.0.3", port: 8765),
        ]
        let result = await RemoteConnectionResolver.resolve(candidates: candidates) { config in
            if config.host == "10.0.0.3" {
                try await Task.sleep(nanoseconds: 300_000_000)
                return "late"
            }
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertEqual(result?.config.host, "10.0.0.3")
        XCTAssertEqual(result?.serverName, "late")
    }

    func testResolve_returnsACandidateFromTheListWhenSeveralSucceed() async {
        let candidates = [
            ServerConfig(host: "10.0.0.1", port: 8765),
            ServerConfig(host: "10.0.0.2", port: 8765),
        ]
        let result = await RemoteConnectionResolver.resolve(candidates: candidates) { _ in "desk" }
        XCTAssertTrue(candidates.map(\.host).contains(result?.config.host ?? ""))
    }

    func testResolve_cancelsSlowProbesAfterFirstSuccess() async {
        let candidates = [
            ServerConfig(host: "10.0.0.1", port: 8765),
            ServerConfig(host: "10.0.0.2", port: 8765),
        ]
        let cancelled = expectation(description: "slow probe cancelled")
        let result = await RemoteConnectionResolver.resolve(candidates: candidates) { config in
            if config.host == "10.0.0.1" {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    cancelled.fulfill()
                    throw error
                }
                return "slow"
            }
            return "fast"
        }
        XCTAssertEqual(result?.config.host, "10.0.0.2")
        await fulfillment(of: [cancelled], timeout: 1.0)
    }

    func testPostSelectionAction_authorisedIsConnected() {
        XCTAssertEqual(DiscoveredPeerAction.after(authorised: true, cameraAvailable: true), .connected)
        XCTAssertEqual(DiscoveredPeerAction.after(authorised: true, cameraAvailable: false), .connected)
    }

    func testPostSelectionAction_unauthorisedWithCameraPresentsScanner() {
        XCTAssertEqual(DiscoveredPeerAction.after(authorised: false, cameraAvailable: true), .presentScanner)
    }

    func testPostSelectionAction_unauthorisedWithoutCameraFocusesPairingCode() {
        XCTAssertEqual(DiscoveredPeerAction.after(authorised: false, cameraAvailable: false), .focusPairingCode)
    }

    func testResolve_returnsNilWhenAllCandidatesFail() async {
        let candidates = [
            ServerConfig(host: "10.0.0.1", port: 8765),
            ServerConfig(host: "10.0.0.2", port: 8765),
        ]
        let result = await RemoteConnectionResolver.resolve(candidates: candidates) { _ in
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertNil(result)
    }

    func testResolve_returnsNilForEmptyCandidates() async {
        let result = await RemoteConnectionResolver.resolve(candidates: []) { _ in "desk" }
        XCTAssertNil(result)
    }

    func testRecoverEndpoint_rejectsDifferentServerDeviceId() async {
        let config = ServerConfig(
            host: "desktop.invalid",
            port: 8765,
            token: "stored-token",
            serverDeviceId: "desktop-1"
        )
        let session = resolverSession { request in
            if request.url?.port == 8766 {
                let data = #"{"deviceId":"other-desktop","hostname":"other","roles":["gui"]}"#.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
            throw URLError(.cannotConnectToHost)
        }

        let endpoint = await RemoteConnectionResolver.recoverEndpoint(
            config: config,
            hosts: ["desktop.invalid"],
            discoveredEndpoint: nil,
            session: session
        )

        XCTAssertNil(endpoint)
    }

    func testRecoverEndpoint_usesDiscoveredEndpointBeforePortProbe() async {
        let session = resolverSession { _ in
            XCTFail("A discovered endpoint should not trigger port probing")
            throw URLError(.cannotConnectToHost)
        }
        let endpoint = await RemoteConnectionResolver.recoverEndpoint(
            config: ServerConfig(host: "desktop.invalid", port: 8765, serverDeviceId: "desktop-1"),
            hosts: ["desktop.invalid"],
            discoveredEndpoint: RemoteConnectionEndpoint(host: "192.168.1.10", port: 8770),
            session: session
        )

        XCTAssertEqual(endpoint, RemoteConnectionEndpoint(host: "192.168.1.10", port: 8770))
    }

    func testRecoverEndpoint_legacyConfigRequiresDesktopRoleAndStoredToken() async {
        let config = ServerConfig(host: "desktop.invalid", port: 8765, token: "stored-token")
        let session = resolverSession { request in
            if request.url?.path == "/v1/identity", request.url?.port == 8766 {
                let data = #"{"deviceId":"desktop-1","hostname":"desk","roles":["headless"]}"#.data(using: .utf8)!
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
            if request.url?.path == "/v1/remote/state", request.url?.port == 8766 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stored-token")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("{}".utf8), response)
            }
            throw URLError(.cannotConnectToHost)
        }

        let endpoint = await RemoteConnectionResolver.recoverEndpoint(
            config: config,
            hosts: ["desktop.invalid"],
            discoveredEndpoint: nil,
            session: session
        )

        XCTAssertEqual(endpoint, RemoteConnectionEndpoint(host: "desktop.invalid", port: 8766))
    }

    /// Second sync bug: reachability (ping, unauthenticated) succeeding does not imply the token is
    /// valid — `checkAuthorised` must distinguish "reachable but 401" from "reachable and authorised".
    func testCheckAuthorised_returnsFalseOn401() async {
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: stubbedSession(statusCode: 401))
        let authorised = await RemoteConnectionResolver.checkAuthorised(client: client)
        XCTAssertFalse(authorised)
    }

    func testCheckAuthorised_returnsTrueOn200() async {
        let client = RemoteAPIClient(baseURLString: "http://127.0.0.1:8765", session: stubbedSession(statusCode: 200))
        let authorised = await RemoteConnectionResolver.checkAuthorised(client: client)
        XCTAssertTrue(authorised)
    }

    func testWithFailover_concurrentFailuresShareOneRecovery() async {
        let clock = TestRecoveryClock()
        let coordinator = RemoteConnectionRecoveryCoordinator(now: { clock.value })
        let probeCount = LockedCounter()
        let session = resolverSession { _ in
            probeCount.increment()
            throw URLError(.cannotConnectToHost)
        }
        let config = ServerConfig(host: "desktop.invalid", port: 8765, token: "stored-token")
        let recoveryGate = RecoveryGate()

        let tasks = (0..<8).map { _ in
            Task {
                do {
                    _ = try await RemoteConnectionResolver.withFailover(
                        config: config,
                        session: session,
                        discover: {
                            await recoveryGate.blockUntilReleased()
                            return nil
                        },
                        persistRecoveredConfig: { _ in },
                        recoveryCoordinator: coordinator,
                        operation: { _ in throw URLError(.cannotConnectToHost) }
                    )
                    XCTFail("Expected the stored connection to remain unavailable")
                } catch {
                    XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
                }
            }
        }

        await recoveryGate.waitUntilStarted()
        await recoveryGate.release()
        for task in tasks { await task.value }

        XCTAssertEqual(probeCount.value, AppConstants.serverPortCandidates.count - 1)
    }

    func testWithFailover_negativeRecoveryCooldownSkipsProbingUntilItExpires() async {
        let clock = TestRecoveryClock()
        let coordinator = RemoteConnectionRecoveryCoordinator(now: { clock.value })
        let probeCount = LockedCounter()
        let session = resolverSession { _ in
            probeCount.increment()
            throw URLError(.cannotConnectToHost)
        }
        let config = ServerConfig(host: "desktop.invalid", port: 8765, token: "stored-token")
        let operation: @Sendable (RemoteAPIClient) async throws -> String = { _ in
            throw URLError(.cannotConnectToHost)
        }

        for _ in 0..<2 {
            do {
                _ = try await RemoteConnectionResolver.withFailover(
                    config: config,
                    session: session,
                    discover: { nil },
                    persistRecoveredConfig: { _ in },
                    recoveryCoordinator: coordinator,
                    operation: operation
                )
                XCTFail("Expected the stored connection to remain unavailable")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
            }
        }
        XCTAssertEqual(probeCount.value, AppConstants.serverPortCandidates.count - 1)

        clock.value += 30
        do {
            _ = try await RemoteConnectionResolver.withFailover(
                config: config,
                session: session,
                discover: { nil },
                persistRecoveredConfig: { _ in },
                recoveryCoordinator: coordinator,
                operation: operation
            )
            XCTFail("Expected the stored connection to remain unavailable")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        XCTAssertEqual(probeCount.value, (AppConstants.serverPortCandidates.count - 1) * 2)
    }

    func testWithFailover_successfulNormalRequestClearsNegativeRecoveryCooldown() async {
        let clock = TestRecoveryClock()
        let coordinator = RemoteConnectionRecoveryCoordinator(now: { clock.value })
        let discoveryCount = LockedCounter()
        let session = resolverSession { _ in
            throw URLError(.cannotConnectToHost)
        }
        let config = ServerConfig(host: "desktop.invalid", port: 8765, token: "stored-token")
        let failingOperation: @Sendable (RemoteAPIClient) async throws -> String = { _ in
            throw URLError(.cannotConnectToHost)
        }

        do {
            _ = try await RemoteConnectionResolver.withFailover(
                config: config,
                session: session,
                discover: {
                    discoveryCount.increment()
                    return nil
                },
                persistRecoveredConfig: { _ in },
                recoveryCoordinator: coordinator,
                operation: failingOperation
            )
            XCTFail("Expected the stored connection to remain unavailable")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        XCTAssertEqual(discoveryCount.value, 1)

        let value = try? await RemoteConnectionResolver.withFailover(
            config: config,
            session: session,
            discover: {
                discoveryCount.increment()
                return nil
            },
            persistRecoveredConfig: { _ in },
            recoveryCoordinator: coordinator,
            operation: { _ in "online" }
        )
        XCTAssertEqual(value?.value, "online")

        do {
            _ = try await RemoteConnectionResolver.withFailover(
                config: config,
                session: session,
                discover: {
                    discoveryCount.increment()
                    return nil
                },
                persistRecoveredConfig: { _ in },
                recoveryCoordinator: coordinator,
                operation: failingOperation
            )
            XCTFail("Expected the stored connection to remain unavailable")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        XCTAssertEqual(discoveryCount.value, 2)
    }
}

private final class TestRecoveryClock: @unchecked Sendable {
    var value: TimeInterval = 0
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private actor RecoveryGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilReleased() async {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }
}

private final class StubURLProtocol: URLProtocol {
    static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let res = HTTPURLResponse(url: request.url!, statusCode: StubURLProtocol.statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: "{}".data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession(statusCode: Int) -> URLSession {
    StubURLProtocol.statusCode = statusCode
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private func resolverSession(
    _ handler: @escaping (URLRequest) throws -> (Data, URLResponse)
) -> URLSession {
    ResolverMockURLProtocol.handler = handler
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ResolverMockURLProtocol.self]
    return URLSession(configuration: config)
}

private final class ResolverMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Data, URLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    func testKeyboardDismissTapMask_isAllOnlyWhileEditing() {
        XCTAssertEqual(SettingsKeyboardDismiss.tapMask(isEditing: true), .all)
        XCTAssertEqual(SettingsKeyboardDismiss.tapMask(isEditing: false), .subviews)
    }

    @MainActor
    func testQRScanner_attachesPreviewLayerSynchronouslyInViewDidLoad() {
        let vc = QRScannerUIViewController()
        vc.loadViewIfNeeded()
        let layers = vc.view.layer.sublayers ?? []
        XCTAssertTrue(layers.contains { $0 is AVCaptureVideoPreviewLayer })
    }
}
