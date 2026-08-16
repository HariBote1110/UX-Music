import Foundation
import Network
import os.log

/// Thin socket layer for the TV's Phase 3-1 remote-command receiver
/// (`markdown/appletv-servermode-plan.md` §3-1, `progress/tvos-connect.md`). All actual
/// decision-making (auth check, action resolution, state JSON shape) lives in the pure types in
/// `TVRemoteCommandHandler.swift`; wire framing lives in `TVRemoteHTTPMessage.swift`. This type's
/// only job is bytes-in → dispatch onto `MusicPlayerService` → bytes-out, plus mDNS advertising.
///
/// Built on `Network.framework` (`NWListener`/`NWConnection`) — there's no server-side
/// `URLSession` equivalent, and this project doesn't have a package-manager-installed HTTP
/// server dependency to reach for.
@MainActor
final class TVRemoteControlServer {
    static let defaultPort: UInt16 = 8766
    /// New service type, distinct from the existing `_uxmusic-sync._tcp` (desktop-to-desktop
    /// Sync discovery) — this one advertises a single TV's remote-command receiver, not a
    /// library-sync peer (see `progress/tvos-connect.md` for why the two aren't merged).
    static let serviceType = "_uxmusic-remote._tcp"

    private let player: MusicPlayerService
    private let token: String
    private let deviceName: String
    private let logger = Logger(subsystem: "com.uxlabs.uxMusicMobile.tv", category: "remote-control-server")
    private var listener: NWListener?

    init(player: MusicPlayerService, token: String, deviceName: String) {
        self.player = player
        self.token = token
        self.deviceName = deviceName
    }

    func start(port: UInt16 = 8766) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: nwPort) else {
            logger.error("failed to bind remote-control listener on port \(port)")
            return
        }
        // §3-1, revised 2026-08-12 (security fix — see `progress/tvos-connect.md`): the receiver's
        // Bearer token is a control token this TV mints and persists for itself
        // (`TVControlTokenStore`) — independent of the host pairing token. Advertising it in the
        // TXT record is how the iOS picker (§3-1 Mobile side) learns it, since there is no
        // separate distribution channel in scope here. Leaking this token only grants control of
        // this TV's own playback — comparable exposure to the existing open pairing endpoints —
        // unlike the host pairing token, which would grant the whole Host `/v1/remote/*` library
        // API. See `progress/tvos-pairing.md` for the underlying LAN-is-the-trust-boundary model.
        listener.service = NWListener.Service(
            name: deviceName,
            type: Self.serviceType,
            txtRecord: Self.encodeTXTRecord(["token": token])
        )
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let data, !data.isEmpty { nextBuffer.append(data) }

            if let request = TVRemoteHTTPRequest.parse(nextBuffer) {
                Task { @MainActor in
                    let response = self.respond(to: request)
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            Task { @MainActor in
                self.receiveRequest(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func respond(to request: TVRemoteHTTPRequest) -> Data {
        switch (request.method, request.path) {
        case ("GET", "/v1/identity"):
            // Public, unauthenticated, same convention as the desktop's `/v1/identity` — used by
            // the iOS picker to confirm this is a TV receiver before sending any command.
            return TVRemoteHTTPResponse.json(TVIdentityPayload.json(deviceName: deviceName))

        case ("GET", "/v1/remote/state"):
            guard isAuthorized(request) else { return TVRemoteHTTPResponse.unauthorized() }
            let song = player.currentSong
            let state = TVRemoteStateBuilder.state(
                title: song?.title ?? "",
                artist: song?.artist ?? "",
                album: song?.album ?? "",
                position: player.positionSeconds,
                duration: player.durationSeconds,
                playing: player.isPlaying,
                volume: Double(player.masterVolume)
            )
            return TVRemoteHTTPResponse.json(state)

        case ("POST", "/v1/remote/command"):
            guard isAuthorized(request) else { return TVRemoteHTTPResponse.unauthorized() }
            return handleCommand(body: request.body)

        default:
            return TVRemoteHTTPResponse.notFound()
        }
    }

    private func isAuthorized(_ request: TVRemoteHTTPRequest) -> Bool {
        TVRemoteAuth.isAuthorized(authorizationHeader: request.header("Authorization"), expectedToken: token)
    }

    private func handleCommand(body: Data) -> Data {
        guard
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let action = obj["action"] as? String
        else {
            return TVRemoteHTTPResponse.json(["ok": false, "error": "invalid body"], status: 400)
        }
        let value = (obj["value"] as? NSNumber)?.doubleValue

        switch TVRemoteCommandHandler.resolve(action: action, value: value) {
        case .success(let resolved):
            dispatch(resolved)
            return TVRemoteHTTPResponse.json(["ok": true])
        case .failure(.missingValue):
            return TVRemoteHTTPResponse.json(["ok": false, "error": "missing value"], status: 400)
        case .failure(.unsupportedAction(let action)):
            return TVRemoteHTTPResponse.json(["ok": false, "error": "unsupported action: \(action)"], status: 400)
        }
    }

    private func dispatch(_ action: TVRemoteCommandHandler.Action) {
        switch action {
        case .toggle:
            player.togglePlayPause()
        case .play:
            if !player.isPlaying { player.togglePlayPause() }
        case .pause:
            if player.isPlaying { player.togglePlayPause() }
        case .next:
            Task { await player.next() }
        case .previous:
            Task { await player.previous() }
        case .seek(let seconds):
            player.seek(to: seconds)
        case .volume(let value):
            player.masterVolume = Float(value)
        }
    }

    /// Encodes a flat `[String: String]` as raw Bonjour TXT record bytes (length-prefixed
    /// `key=value` entries), rather than depending on the newer `NWTXTRecord` convenience type,
    /// so this keeps working against the tvOS 17 minimum deployment target this project targets.
    private static func encodeTXTRecord(_ fields: [String: String]) -> Data {
        var data = Data()
        for (key, value) in fields {
            let entry = Array("\(key)=\(value)".utf8prefix(255))
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
        return data
    }
}

private extension String {
    /// UTF-8 bytes truncated to `maxLength` bytes (TXT record entries are limited to 255 bytes).
    func utf8prefix(_ maxLength: Int) -> [UInt8] {
        Array(utf8.prefix(maxLength))
    }
}
