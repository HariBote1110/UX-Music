import AVFoundation
import Combine
import Foundation

/// Plays the host's YouTube LAN relay stream (`GET /v1/remote/relay`, Phase 3-3 receiver) via
/// `AVPlayer`.
///
/// **Auth**: the relay endpoint only accepts the `Authorization` header — no `?token=` query
/// fallback (see `RemoteAPIClient.relayRequest()`'s doc comment and
/// `server/app_apierror.go`'s `isMediaQueryTokenEndpoint`). So this builds an `AVURLAsset` with
/// `AVURLAssetHTTPHeaderFieldsKey` rather than handing `AVPlayer` a bare authenticated-by-query URL.
///
/// **Failure recovery** (see `progress/tvos-relay-reception.md`): the host streams raw chunked
/// ADTS AAC-LC elementary-stream audio, which is an unverified risk for `AVPlayer` — a real device
/// report confirmed it can fail to decode, and previously that left the app stuck as if the relay
/// were still active, blocking local playback entirely. This controller now watches for three
/// failure signals — `AVPlayerItem.status == .failed`, `AVPlayerItemFailedToPlayToEndTime`, and an
/// ~8s startup timeout if playback never actually starts (`rate` never goes above 0) — and on any
/// of them tears the relay session down completely and transitions to `.failed`, which
/// `TVRelayPlaybackReducer.isLocalPlaybackUsable` always reports as player-usable. The state
/// machine itself lives in `TVRelayPlaybackReducer` so the transitions are pure-logic testable;
/// this type only wires `AVPlayer`'s side effects into it.
@MainActor
final class TVRelayPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var state: TVRelayPlaybackState = .idle

    private let client: RemoteAPIClient
    private let startupTimeout: TimeInterval
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var didStartPlaying = false

    init(client: RemoteAPIClient, startupTimeout: TimeInterval = 8) {
        self.client = client
        self.startupTimeout = startupTimeout
    }

    /// Starts (or restarts) relay playback. Callers are responsible for stopping local
    /// `MusicPlayerService` playback first — this controller only owns the relay `AVPlayer`.
    func start() {
        teardown()
        state = TVRelayPlaybackReducer.reduce(state, event: .start)
        didStartPlaying = false

        guard let request = try? client.relayRequest(), let url = request.url else {
            fail(reason: String(localized: "tv.relay.error.requestFailed"))
            return
        }

        // `AVURLAssetHTTPHeaderFieldsKey` is not declared in the tvOS SDK's public headers (it is
        // on iOS), but the informal string key is still honoured by `AVURLAsset` on tvOS, so it's
        // passed as a raw string literal here rather than the (unavailable) named constant.
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:],
                AVURLAssetOverrideMIMETypeKey: "audio/aac"
            ]
        )
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard observedItem.status == .failed else { return }
            let message = observedItem.error?.localizedDescription
                ?? String(localized: "tv.relay.error.unknown")
            Task { @MainActor [weak self] in
                self?.fail(reason: message)
            }
        }
        rateObservation = newPlayer.observe(\.rate, options: [.new]) { [weak self] observedPlayer, _ in
            guard observedPlayer.rate > 0 else { return }
            Task { @MainActor [weak self] in
                self?.didStartPlaying = true
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                ?? String(localized: "tv.relay.error.unknown")
            Task { @MainActor [weak self] in
                self?.fail(reason: message)
            }
        }
        timeoutTask = Task { [weak self, startupTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(startupTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.didStartPlaying else { return }
                self.fail(reason: String(localized: "tv.relay.error.timeout"))
            }
        }

        newPlayer.play()
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

    /// Releases every `AVPlayer`-side resource (player, observations, notification, timeout task)
    /// without touching `state` — callers decide the resulting state (`stop()` → `.idle`,
    /// `fail(reason:)` → `.failed`).
    private func teardown() {
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        failureObserver = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        player?.pause()
        player = nil
    }
}
