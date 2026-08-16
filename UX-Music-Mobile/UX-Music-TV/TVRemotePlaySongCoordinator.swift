import Foundation

/// Side-effecting driver for the "PC経由で再生中" flow (`progress/tvos-relay-reception.md` 追記):
/// posts `play-song` to the paired host, then polls `GET /v1/remote/state` until `relay.active`
/// flips true (or a ~10s timeout elapses), and finally hands off to the existing
/// `TVRelayPlaybackController`/`TVRelayStreamPlayer` reception path — the same one the "PCで再生中
/// のYouTube" shelf entry already uses. The pure state transitions live in
/// `TVRemotePlaySongReducer`; this type only wires `RemoteAPIClient` calls and a poll loop into it,
/// mirroring how `TVRelayPlaybackController` wires `TVRelayStreamPlayer` into
/// `TVRelayPlaybackReducer`.
@MainActor
final class TVRemotePlaySongCoordinator: ObservableObject {
    @Published private(set) var state: TVRemotePlaySongState = .idle

    private let client: RemoteAPIClient
    private let relayPlaybackController: TVRelayPlaybackController
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval
    private var runTask: Task<Void, Never>?

    init(
        client: RemoteAPIClient,
        relayPlaybackController: TVRelayPlaybackController,
        pollInterval: TimeInterval = 0.5,
        timeout: TimeInterval = 10
    ) {
        self.client = client
        self.relayPlaybackController = relayPlaybackController
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    /// Starts (or restarts) the remote-play attempt for `songId`. Callers are responsible for
    /// presenting the waiting/relay UI — this coordinator only owns the network flow and, once
    /// `relay.active` is observed, starting `relayPlaybackController`.
    func start(songId: String) {
        runTask?.cancel()
        state = TVRemotePlaySongReducer.reduce(state, event: .start)
        runTask = Task { [weak self] in
            await self?.run(songId: songId)
        }
    }

    /// Cancels any in-flight attempt and returns to `.idle`. Called both when the user exits the
    /// waiting/relay UI and before starting a fresh attempt.
    func cancel() {
        runTask?.cancel()
        runTask = nil
        state = TVRemotePlaySongReducer.reduce(state, event: .exit)
    }

    private func run(songId: String) async {
        do {
            try await client.sendPlaySongCommand(songId: songId)
        } catch RemoteAPIError.server(let code, _) where code == "gui_required" {
            guard !Task.isCancelled else { return }
            state = TVRemotePlaySongReducer.reduce(
                state,
                event: .sendFailed(reason: String(localized: "tv.remotePlay.error.guiRequired"))
            )
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = TVRemotePlaySongReducer.reduce(
                state,
                event: .sendFailed(reason: String(localized: "tv.remotePlay.error.requestFailed"))
            )
            return
        }
        guard !Task.isCancelled else { return }
        state = TVRemotePlaySongReducer.reduce(state, event: .sendSucceeded)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return }
            if let json = try? await client.fetchState() {
                let relay = TVRelayStateBlock.parse(fromStateJSON: json)
                if relay.active {
                    guard !Task.isCancelled else { return }
                    state = TVRemotePlaySongReducer.reduce(state, event: .relayActive)
                    relayPlaybackController.start()
                    return
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        state = TVRemotePlaySongReducer.reduce(state, event: .timedOut)
    }
}
