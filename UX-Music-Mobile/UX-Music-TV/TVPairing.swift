import Foundation

/// Result of `POST /v1/pairing/start`, mirroring the desktop-to-desktop flow's
/// `SyncPairingStartResult` (see `server/app_sync.go`).
struct TVPairingStart: Equatable, Sendable {
    let sessionId: String
    let code: String
    let expiresAt: String
}

/// Result of `POST /v1/pairing/confirm`.
struct TVPairingConfirmed: Equatable, Sendable {
    let deviceId: String
    let token: String
}

enum TVPairingError: Error, Equatable {
    case network(String)
    case invalidResponse
}

/// Network seam for the pairing calls, so the state machine and `TVAppModel` can be exercised
/// with a stub in tests without touching a real host. The real implementation
/// (`URLSessionTVPairingClient`) issues the same `/v1/pairing/start` and `/v1/pairing/confirm`
/// requests the desktop app makes in `server/app_sync.go`'s `StartSyncPairing`/`ConfirmSyncPairing`.
protocol TVPairingClient: Sendable {
    func start(baseURL: String, deviceId: String, displayName: String) async throws -> TVPairingStart
    func confirm(baseURL: String, sessionId: String, code: String) async throws -> TVPairingConfirmed
}

/// States of the TV pairing flow (Phase 1-2). Unlike the mobile QR flow, the TV is the
/// *initiator*: it discovers a host via mDNS, calls `start` itself, and displays the returned
/// 6-digit code full-screen.
///
/// Trust-model note (see `progress/tvos-pairing.md`): the existing desktop-to-desktop flow does
/// not require a separate host-side human approval step — `/v1/pairing/start` returns the code
/// directly to whoever calls it, and that caller can immediately call `/v1/pairing/confirm` with
/// it. The TV flow reuses this unchanged: after `start` succeeds the code is shown on screen and
/// `confirm` is issued automatically with the same code, exactly mirroring what the desktop
/// settings UI does when a human clicks 開始 followed immediately by 確定.
enum TVPairingState: Equatable {
    case idle
    case starting(hostDisplayName: String)
    case awaitingConfirmation(hostDisplayName: String, start: TVPairingStart)
    case confirming(hostDisplayName: String, start: TVPairingStart)
    case paired(hostDisplayName: String, deviceId: String)
    case failed(message: String)
}

/// Pure reducer for the pairing state machine — no networking, fully unit-testable.
enum TVPairingReducer {
    enum Event {
        case selectedHost(displayName: String)
        case startSucceeded(TVPairingStart)
        case startFailed(String)
        case confirmSucceeded(deviceId: String)
        case confirmFailed(String)
        case reset
    }

    static func reduce(_ state: TVPairingState, _ event: Event) -> TVPairingState {
        switch event {
        case .selectedHost(let displayName):
            return .starting(hostDisplayName: displayName)

        case .startSucceeded(let start):
            guard case .starting(let hostDisplayName) = state else { return state }
            return .awaitingConfirmation(hostDisplayName: hostDisplayName, start: start)

        case .startFailed(let message):
            guard case .starting = state else { return state }
            return .failed(message: message)

        case .confirmSucceeded(let deviceId):
            guard case .confirming(let hostDisplayName, _) = state else { return state }
            return .paired(hostDisplayName: hostDisplayName, deviceId: deviceId)

        case .confirmFailed(let message):
            guard case .confirming = state else { return state }
            return .failed(message: message)

        case .reset:
            return .idle
        }
    }

    /// Transitions `awaitingConfirmation` into `confirming` once the automatic confirm call is
    /// issued. Split from `startSucceeded` because the TV app model drives this transition itself
    /// (it needs the `TVPairingStart` payload to make the network call in between).
    static func beginConfirming(_ state: TVPairingState) -> TVPairingState {
        guard case .awaitingConfirmation(let hostDisplayName, let start) = state else { return state }
        return .confirming(hostDisplayName: hostDisplayName, start: start)
    }
}
