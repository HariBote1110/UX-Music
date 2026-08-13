import AVFoundation
import Foundation

/// Drives Task A's stream-first playback path for a cache miss: plays `GET /v1/remote/file?id=…
/// &stream=aac` immediately via a reused `TVRelayStreamPlayer` (same ADTS/AAC-LC 256kbps/44.1kHz
/// format as the relay) while the original file downloads in the background into
/// `TVPlaybackCacheStore` for the NEXT play. See `progress/tvos-playback.md` "ストリームファースト
/// 再生" 追記 for the full design and the EQ/LUFS routing decision.
///
/// Mirrors `TVRelayPlaybackController`'s split: this type owns only network+decode+playback side
/// effects; the loading→streaming→finished/failed transitions live in the pure, independently
/// tested `TVSongStreamPlaybackReducer`.
@MainActor
final class TVSongStreamController: ObservableObject {
    @Published private(set) var state: TVSongStreamPlaybackState = .idle

    private let client: RemoteAPIClient
    private let startupTimeout: TimeInterval
    private var streamPlayer: TVRelayStreamPlayer?
    private var timeoutTask: Task<Void, Never>?
    private var didStartPlaying = false

    /// Called exactly once per stream, either when the track finishes naturally
    /// (`didReachEndOfStream`) or when the stream fails outright — the caller (`TVPlaybackController`)
    /// uses this to decide whether/how to advance the queue, matching
    /// `MusicPlayerService.onTrackNaturallyFinished`'s natural-end-only contract for the finished
    /// case. Failures are reported too (with `didFinishNaturally: false`) so the caller can fall
    /// back rather than silently going quiet.
    var onStreamEnded: ((_ didFinishNaturally: Bool) -> Void)?

    init(client: RemoteAPIClient, startupTimeout: TimeInterval = 8) {
        self.client = client
        self.startupTimeout = startupTimeout
    }

    /// Starts (or restarts) the stream-first path for `songId`. `outputGain` is the linear LUFS
    /// gain to apply (same formula as `MusicPlayerService.applyLoudnessGain()`) — computed by the
    /// caller since it already owns `loudnessMap`/`targetLoudness`.
    func start(songId: String, outputGain: Float) {
        teardown()
        state = TVSongStreamPlaybackReducer.reduce(state, event: .start)
        didStartPlaying = false

        guard let request = try? client.songStreamRequest(songId: songId) else {
            fail(reason: String(localized: "tv.stream.error.unknown"))
            return
        }

        let newPlayer = TVRelayStreamPlayer()
        newPlayer.outputGain = outputGain
        newPlayer.delegate = self
        streamPlayer = newPlayer

        timeoutTask = Task { [weak self, startupTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(startupTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.didStartPlaying else { return }
                self.fail(reason: String(localized: "tv.stream.error.unknown"))
            }
        }

        newPlayer.start(request: request)
    }

    /// Tears the stream down without touching `state` — used when a different song is about to
    /// start playing (cache hit or another stream) and the previous one is no longer relevant.
    func stop() {
        teardown()
        state = TVSongStreamPlaybackReducer.reduce(state, event: .reset)
    }

    private func fail(reason: String) {
        guard state == .loading || state == .streaming else { return }
        teardown()
        state = TVSongStreamPlaybackReducer.reduce(state, event: .fail(reason: reason))
        onStreamEnded?(false)
    }

    private func teardown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        streamPlayer?.delegate = nil
        streamPlayer?.stop()
        streamPlayer = nil
    }
}

extension TVSongStreamController: TVRelayStreamPlayerDelegate {
    func relayStreamPlayerDidStartRendering(_ player: TVRelayStreamPlayer) {
        didStartPlaying = true
        state = TVSongStreamPlaybackReducer.reduce(state, event: .didStartRendering)
    }

    func relayStreamPlayer(_ player: TVRelayStreamPlayer, didFailWith reason: String) {
        fail(reason: reason)
    }

    func relayStreamPlayerDidReachEndOfStream(_ player: TVRelayStreamPlayer) {
        guard state == .streaming else { return } // ignore late callback after teardown/fail
        teardown()
        state = TVSongStreamPlaybackReducer.reduce(state, event: .didReachEndOfStream)
        onStreamEnded?(true)
    }
}
