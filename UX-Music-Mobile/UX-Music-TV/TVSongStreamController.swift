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
    /// Builds the `TVRelayStreamPlayer` for each `start()` call. Defaults to the plain production
    /// initialiser; overridable so DEBUG preview harnesses / tests can point playback at a mock
    /// `URLSessionConfiguration` (e.g. `UXTV_PREVIEW=songstream`, see `UXMusicTVApp.swift`)
    /// without needing a live host.
    private let streamPlayerFactory: () -> TVRelayStreamPlayer
    private var streamPlayer: TVRelayStreamPlayer?
    private var timeoutTask: Task<Void, Never>?
    private var didStartPlaying = false
    private(set) var isPaused = false

    /// Elapsed playback position of the current stream, or `0` when idle. See
    /// `TVRelayStreamPlayer.elapsedSeconds`.
    var elapsedSeconds: Double { streamPlayer?.elapsedSeconds ?? 0 }

    /// Called exactly once per stream, either when the track finishes naturally
    /// (`didReachEndOfStream`) or when the stream fails outright — the caller (`TVPlaybackController`)
    /// uses this to decide whether/how to advance the queue, matching
    /// `MusicPlayerService.onTrackNaturallyFinished`'s natural-end-only contract for the finished
    /// case. Failures are reported too (with `didFinishNaturally: false`) so the caller can fall
    /// back rather than silently going quiet.
    var onStreamEnded: ((_ didFinishNaturally: Bool) -> Void)?

    init(
        client: RemoteAPIClient,
        startupTimeout: TimeInterval = 8,
        streamPlayerFactory: @escaping () -> TVRelayStreamPlayer = { TVRelayStreamPlayer() }
    ) {
        self.client = client
        self.startupTimeout = startupTimeout
        self.streamPlayerFactory = streamPlayerFactory
    }

    /// Starts (or restarts) the stream-first path for `songId`. `outputGain` is the linear LUFS
    /// gain to apply (same formula as `MusicPlayerService.applyLoudnessGain()`) — computed by the
    /// caller since it already owns `loudnessMap`/`targetLoudness`.
    func start(songId: String, outputGain: Float) {
        teardown()
        state = TVSongStreamPlaybackReducer.reduce(state, event: .start)
        didStartPlaying = false
        isPaused = false

        guard let request = try? client.songStreamRequest(songId: songId) else {
            fail(reason: String(localized: "tv.stream.error.unknown"))
            return
        }

        let newPlayer = streamPlayerFactory()
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

    /// Pauses/resumes the live stream in place — routed here from
    /// `MusicPlayerService.togglePlayPause()` via `externalPlaybackCommandHandler` while streaming
    /// owns Now Playing (`progress/tvos-playback.md` "Now Playing 統合"). No-op before playback has
    /// actually started (nothing to pause yet).
    func togglePlayPause() {
        guard let streamPlayer, didStartPlaying else { return }
        if isPaused {
            streamPlayer.resume()
        } else {
            streamPlayer.pause()
        }
        isPaused.toggle()
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
    /// Every callback below first checks `player === streamPlayer` — defence in depth alongside
    /// `TVRelayStreamPlayer`'s own generation guard. `teardown()` always nils the outgoing
    /// player's `delegate` synchronously on the MainActor before a new one starts, so this should
    /// already be unreachable for a superseded session in practice; the identity check makes that
    /// an enforced invariant rather than an emergent property of call ordering
    /// (`progress/tvos-playback-concurrency.md` "sessionID gating").
    func relayStreamPlayerDidStartRendering(_ player: TVRelayStreamPlayer) {
        guard player === streamPlayer else { return }
        didStartPlaying = true
        state = TVSongStreamPlaybackReducer.reduce(state, event: .didStartRendering)
    }

    func relayStreamPlayer(_ player: TVRelayStreamPlayer, didFailWith reason: String) {
        guard player === streamPlayer else { return }
        fail(reason: reason)
    }

    func relayStreamPlayerDidReachEndOfStream(_ player: TVRelayStreamPlayer) {
        guard player === streamPlayer else { return }
        guard state == .streaming else { return } // ignore late callback after teardown/fail
        teardown()
        state = TVSongStreamPlaybackReducer.reduce(state, event: .didReachEndOfStream)
        onStreamEnded?(true)
    }
}
