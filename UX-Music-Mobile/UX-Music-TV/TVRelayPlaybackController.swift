import AVFoundation
import Combine
import Foundation

/// Plays the host's YouTube LAN relay stream (`GET /v1/remote/relay`, Phase 3-3 receiver) via
/// `TVRelayStreamPlayer`, a custom ADTS-parsing/decoding player.
///
/// **Auth**: the relay endpoint only accepts the `Authorization` header — no `?token=` query
/// fallback (see `RemoteAPIClient.relayRequest()`'s doc comment and
/// `server/app_apierror.go`'s `isMediaQueryTokenEndpoint`). `RemoteAPIClient.relayRequest()`
/// already builds a `URLRequest` with that header set, which is handed straight to
/// `TVRelayStreamPlayer.start(request:)`.
///
/// **Why not `AVPlayer`** (confirmed on real hardware, see `progress/tvos-relay-reception.md`):
/// the host streams raw chunked ADTS AAC-LC elementary-stream audio (no container), which
/// `AVPlayer`/`AVURLAsset` cannot play at all — not merely "can fail", but a consistent hard
/// failure. `TVRelayStreamPlayer` parses ADTS frames itself (`ADTSFrameParser`) and decodes them
/// via `AVAudioConverter` (`TVAACDecoder`) onto a dedicated `AVAudioEngine`.
///
/// **Failure recovery** (see `progress/tvos-relay-reception.md`): this controller watches for two
/// failure signals from `TVRelayStreamPlayer` — an explicit failure callback (network error,
/// non-2xx response, unrecoverable decode failure) and an ~8s startup timeout if the stream never
/// actually starts rendering PCM — and on either tears the relay session down completely and
/// transitions to `.failed`, which `TVRelayPlaybackReducer.isLocalPlaybackUsable` always reports
/// as player-usable. The state machine itself lives in `TVRelayPlaybackReducer` so the
/// transitions are pure-logic testable; this type only wires `TVRelayStreamPlayer`'s side effects
/// into it.
@MainActor
final class TVRelayPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var state: TVRelayPlaybackState = .idle

    private let client: RemoteAPIClient
    private let startupTimeout: TimeInterval
    private var streamPlayer: TVRelayStreamPlayer?
    private var timeoutTask: Task<Void, Never>?
    private var didStartPlaying = false

    init(client: RemoteAPIClient, startupTimeout: TimeInterval = 8) {
        self.client = client
        self.startupTimeout = startupTimeout
    }

    /// Starts (or restarts) relay playback. Callers are responsible for stopping local
    /// `MusicPlayerService` playback first — this controller only owns the relay stream player.
    func start() {
        teardown()
        state = TVRelayPlaybackReducer.reduce(state, event: .start)
        didStartPlaying = false

        guard let request = try? client.relayRequest() else {
            fail(reason: String(localized: "tv.relay.error.requestFailed"))
            return
        }

        let newPlayer = TVRelayStreamPlayer()
        newPlayer.delegate = self
        streamPlayer = newPlayer

        timeoutTask = Task { [weak self, startupTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(startupTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.didStartPlaying else { return }
                self.fail(reason: String(localized: "tv.relay.error.timeout"))
            }
        }

        newPlayer.start(request: request)
        isPlaying = true
    }

    /// Stops the relay stream, if any, and returns to `.idle` (player usable). Safe to call when
    /// nothing is playing. Called both when the user exits the relay banner and before starting a
    /// fresh attempt.
    func stop() {
        teardown()
        state = TVRelayPlaybackReducer.reduce(state, event: .exit)
        isPlaying = false
    }

    /// Tears the relay session down (matching `TVRelayPlaybackReducer`'s `.fail` transition) and
    /// records `reason` for the UI's localised error banner. Guards against double-fail if two
    /// failure signals arrive in quick succession.
    private func fail(reason: String) {
        guard case .playing = state else { return }
        teardown()
        state = TVRelayPlaybackReducer.reduce(.playing, event: .fail(reason: reason))
        isPlaying = false
    }

    /// Releases every `TVRelayStreamPlayer`-side resource (network task, audio engine, timeout
    /// task) without touching `state` — callers decide the resulting state (`stop()` → `.idle`,
    /// `fail(reason:)` → `.failed`).
    private func teardown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        streamPlayer?.delegate = nil
        streamPlayer?.stop()
        streamPlayer = nil
    }
}

extension TVRelayPlaybackController: TVRelayStreamPlayerDelegate {
    func relayStreamPlayerDidStartRendering(_ player: TVRelayStreamPlayer) {
        didStartPlaying = true
    }

    func relayStreamPlayer(_ player: TVRelayStreamPlayer, didFailWith reason: String) {
        fail(reason: reason)
    }
}
