import Combine
import Foundation

/// Whether the host advertises the Phase 3-3 YouTube LAN relay (`markdown/appletv-servermode-plan.md`
/// §3-3). Matches `remoteRelayCapability` in `server/app_remote_relay.go` — present in
/// `GET /v1/identity`'s `capabilities` array only in GUI mode, so a headless host or an older
/// desktop build that predates this feature simply omits it.
enum TVRelayCapability {
    static let identifier = "remote.relay.v1"

    static func isPresent(in capabilities: [String]) -> Bool {
        capabilities.contains(identifier)
    }
}

/// Pure parse of the additive `relay` block in `GET /v1/remote/state`
/// (`{"active": Bool, "title": String, "thumbnail": String}`, see `server/app_remote.go`'s
/// `remoteStateHandler`). Missing/malformed data degrades to `.inactive` rather than throwing —
/// this block is additive and optional, so a host that hasn't started relaying anything (or an
/// older host without the key at all) should read as simply "not available", not an error.
struct TVRelayStateBlock: Equatable {
    let active: Bool
    let title: String
    let thumbnail: String

    static let inactive = TVRelayStateBlock(active: false, title: "", thumbnail: "")

    static func parse(fromStateJSON json: [String: Any]) -> TVRelayStateBlock {
        guard let relay = json["relay"] as? [String: Any] else { return .inactive }
        return TVRelayStateBlock(
            active: relay["active"] as? Bool ?? false,
            title: relay["title"] as? String ?? "",
            thumbnail: relay["thumbnail"] as? String ?? ""
        )
    }
}

/// Pure parse of the root-level `playing` key in `GET /v1/remote/state`
/// (`server/app_audio.go`'s `AudioGetStatus`) — the HOST's own transport state, which the relay
/// banner's play/pause button reflects (`progress/tvos-relay-reception.md` 追記 — relay transport
/// controls). Missing/malformed data defaults to `true` (the expected state right after a relay
/// starts) rather than throwing, matching `TVRelayStateBlock`'s degrade-gracefully approach for
/// this additive-ish field.
enum TVRelayTransportState {
    static func isPlaying(fromStateJSON json: [String: Any], defaultingTo fallback: Bool = true) -> Bool {
        json["playing"] as? Bool ?? fallback
    }
}

/// The single rule deciding whether the browse UI shows the relay shelf entry: the host must both
/// support the feature (capability present — guards older hosts) AND currently have something
/// actively relaying (guards the common case of a capable host with nothing playing).
enum TVRelayAvailability {
    static func isAvailable(capabilities: [String], relay: TVRelayStateBlock) -> Bool {
        TVRelayCapability.isPresent(in: capabilities) && relay.active
    }
}

/// Polls the host for relay availability/metadata so `TVBrowseView` can show or hide the
/// "PCで再生中のYouTube" shelf entry and keep its title/thumbnail current. Capabilities are
/// fetched once (server mode doesn't change while the TV is connected) and cached; the `relay`
/// block is re-fetched on every poll tick since it changes as the user starts/stops YouTube
/// playback on the host.
@MainActor
final class TVRelayModel: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var title = ""
    @Published private(set) var thumbnail = ""
    /// Root-level `playing` key from `GET /v1/remote/state` (`server/app_audio.go`'s
    /// `AudioGetStatus`) — reflects the HOST's own transport state (which the relay banner's
    /// play/pause button drives via `POST /v1/remote/command`), not anything local to the TV.
    /// Defaults to `true` so the transport button shows "pause" (the expected state right after
    /// a relay starts) until the first poll tick resolves the real value.
    @Published private(set) var isPlaying = true

    private let client: RemoteAPIClient
    private var capabilities: [String] = []
    private var pollTask: Task<Void, Never>?

    init(client: RemoteAPIClient) {
        self.client = client
    }

    func startPolling(interval: TimeInterval = 5) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshCapabilitiesIfNeeded()
                await self.refreshState()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refreshCapabilitiesIfNeeded() async {
        guard capabilities.isEmpty else { return }
        capabilities = (try? await client.fetchIdentityCapabilities()) ?? []
    }

    private func refreshState() async {
        guard let json = try? await client.fetchState() else { return }
        let relay = TVRelayStateBlock.parse(fromStateJSON: json)
        isAvailable = TVRelayAvailability.isAvailable(capabilities: capabilities, relay: relay)
        title = relay.title
        thumbnail = relay.thumbnail
        isPlaying = TVRelayTransportState.isPlaying(fromStateJSON: json, defaultingTo: isPlaying)
    }
}
