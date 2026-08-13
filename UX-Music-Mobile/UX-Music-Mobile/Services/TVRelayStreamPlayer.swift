import AVFoundation
import Foundation

/// Signals from `TVRelayStreamPlayer` that `TVRelayPlaybackController` maps onto
/// `TVRelayPlaybackReducer` events. Deliberately narrow — this type owns only network + decode +
/// playback, not the relay lifecycle state machine (see `TVRelayPlaybackReducer`).
protocol TVRelayStreamPlayerDelegate: AnyObject {
    /// The first PCM buffer has actually been scheduled on the audio engine — this is "startup
    /// success" for the controller's 8s startup timeout.
    func relayStreamPlayerDidStartRendering(_ player: TVRelayStreamPlayer)
    /// The network connection ended (host stopped, error, non-2xx) or decode failed
    /// unrecoverably. `reason` is a user-facing (already localised where possible) string.
    func relayStreamPlayer(_ player: TVRelayStreamPlayer, didFailWith reason: String)
    /// The HTTP body ended with NO error (`didCompleteWithError: nil`) — i.e. a normal,
    /// successful end of stream. The continuous YouTube relay never reaches this in practice
    /// (the host keeps the connection open for as long as it's relaying), but Task A's
    /// per-song stream (`GET /v1/remote/file?id=…&stream=aac`) is finite: the desktop closes
    /// the connection once the whole track has been sent, and THAT is this type's only signal
    /// that the track finished — there is no separate "end of track" marker in the ADTS byte
    /// stream itself. Default no-op via the protocol extension below so `TVRelayPlaybackController`
    /// (which never expects to see this) doesn't need to implement it.
    func relayStreamPlayerDidReachEndOfStream(_ player: TVRelayStreamPlayer)
}

extension TVRelayStreamPlayerDelegate {
    func relayStreamPlayerDidReachEndOfStream(_ player: TVRelayStreamPlayer) {}
}

/// Plays the host's YouTube LAN relay stream (`GET /v1/remote/relay`) by parsing and decoding the
/// raw chunked ADTS AAC-LC elementary stream itself, rather than handing the URL to `AVPlayer`.
///
/// **Why not `AVPlayer`** (confirmed on real hardware, see `progress/tvos-relay-reception.md`):
/// `GET /v1/remote/relay` is a container-less chunked ADTS stream, and `AVPlayer` cannot play it —
/// `AVURLAsset` never resolves a playable item. `AVAudioFile`/`AVPlayer` both expect either a
/// real container (movie/CAF/WAV) or a locally-seekable file, neither of which a live chunked
/// HTTP body provides.
///
/// **Architecture**: `URLSession` streaming data task → `ADTSFrameParser` (pure incremental byte
/// parser) → `TVAACDecoder` (`AVAudioConverter` AAC→PCM) → a small jitter buffer → a *dedicated*
/// `AVAudioEngine`/`AVAudioPlayerNode`, not `MusicPlayerService`'s engine. See "Engine choice"
/// below for why.
///
/// **Engine choice — dedicated engine, not `MusicPlayerService`'s**: `TVRelayPlaybackController`
/// requires local `MusicPlayerService` playback to already be stopped before starting a relay
/// session (see its doc comment), so there's no concurrent-engine-use hazard either way. Reusing
/// `MusicPlayerService`'s engine would mean reaching into its private `AVAudioEngine`/EQ graph
/// from a completely different subsystem, coupling two independently-testable pieces for no
/// benefit (the relay stream doesn't need the 10-band EQ or LUFS normalisation — it's the host's
/// own downstream mix already). A small standalone engine, started on `start()` and fully torn
/// down on `stop()`/failure, is simpler to reason about and keeps this type unit-of-deployment
/// independent — matching the brief's "pick the simpler safe option".
///
/// **Jitter buffer**: decoded PCM is queued and playback only starts once ~0.75s of audio is
/// buffered (`jitterBufferSeconds`), smoothing out network scheduling jitter from the chunked
/// transfer without adding much perceptible latency.
///
/// **EQ routing decision (Task A, `progress/tvos-playback.md`)**: this type is now reused for two
/// call sites — the continuous relay (unchanged) and Task A's per-song stream-first playback path
/// for cache misses. `MusicPlayerService`'s 10-band `AVAudioUnitEQ` is a private node fully owned
/// by its own engine (confirmed by reading `MusicPlayerService.swift`); there is no reusable public
/// EQ graph to attach here, and re-implementing a second 10-band EQ purely for the ~seconds-long
/// window before the cached original takes over on the next play was judged not worth the
/// complexity. What DOES matter for the cache-miss case is loudness: playing an un-normalised
/// stream noticeably louder/quieter than the cached-path `MusicPlayerService.applyLoudnessGain()`
/// track before it would be a jarring level jump. So this player applies ONLY the LUFS gain
/// (`outputGain`, same linear-gain formula as `MusicPlayerService`) via `mainMixerNode.outputVolume`
/// — cheap, no extra node needed — and skips the 10-band EQ curve for the streamed portion of a
/// song. The very same song immediately gets full EQ once it's next played from the
/// `TVPlaybackCacheStore`-cached original (`TVPlaybackController`'s background download). Documented
/// as the pragmatic first step; a shared EQ graph is future work if the loudness-only gap proves
/// audible in practice.
/// Not `final`: `TVPlaybackControllerStreamSwitchTests` subclasses this to tag/count
/// `pause()`/`resume()` calls per session (no other seam exists to prove pause/resume route to the
/// CURRENT stream, not a superseded one — see that test file's doc comment).
class TVRelayStreamPlayer: NSObject {
    weak var delegate: TVRelayStreamPlayerDelegate?

    private let jitterBufferSeconds: Double
    private let session: URLSession
    private var task: URLSessionDataTask?
    private var parser = ADTSFrameParser()
    private var decoder: TVAACDecoder?
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var didStartRendering = false
    private var bufferedSeconds: Double = 0
    private var lastRMSLogTime = Date.distantPast
    private var isEngineConnected = false
    private let muteOutput: Bool

    /// Serialises every touch of `engine`/`playerNode`/`isEngineConnected` between two otherwise
    /// racing call paths: `stop()` (always called from the owning controller's actor, i.e. the
    /// main thread) and `URLSessionDataDelegate` callbacks (delivered on `session`'s delegate
    /// queue, a background queue, from `handle`/`schedule`). Before this queue existed, a chunk
    /// already in flight when the user backed out could run `schedule()`'s
    /// `engine.connect(playerNode, …)` concurrently with `stop()`'s `engine.detach(playerNode)`
    /// on the main thread — exactly the crash from the real-device repro
    /// (`AVAEInternal.h:71 … [_nodes containsObject: node1] && [_nodes containsObject: node2]`):
    /// `connect` observing a node that had just been detached out from under it, or not yet
    /// (re-)attached. Routing every engine mutation through this single serial queue makes
    /// `start()`, `schedule()` and `stop()` totally ordered with respect to each other, so the
    /// detach in `stop()` can never interleave with a connect/attach elsewhere. `stop()` uses
    /// `sync` so it does not return until any in-flight schedule has fully completed, guaranteeing
    /// the engine is inert before the caller starts a new session on the same or a new player
    /// instance. See `progress/tvos-playback.md` for the full root-cause writeup.
    private let engineQueue = DispatchQueue(label: "com.uxmusic.tv.relaystreamplayer.engine")
    /// Bumped on every `start()`/`stop()`; frame-handling closures captured on `engineQueue` before
    /// the stop check this against the value they captured and no-op if it has since changed, so
    /// any chunk that was already enqueued on `engineQueue` when `stop()` was called is discarded
    /// rather than touching a torn-down engine.
    ///
    /// Guarded by `generationLock`, NOT `engineQueue` (`progress/tvos-playback.md` "engineQueue↔
    /// MainActor デッドロック" 追記): `start()`/`stop()` must be able to bump this from the MainActor
    /// WITHOUT waiting for `engineQueue` — see `bumpGeneration()`/`start()`/`stop()` below for why
    /// they now use `engineQueue.async` (never `.sync`) for the actual engine teardown/setup work.
    private let generationLock = NSLock()
    private var _generation: Int = 0

    /// Guards `cachedElapsedSeconds` ONLY — deliberately a separate, always-cheap lock rather than
    /// routing `elapsedSeconds` through `engineQueue.sync` (`progress/tvos-playback-concurrency.md`
    /// "MainActor→engineQueue.sync" 追記). The 250ms progress-mirror poll
    /// (`TVPlaybackController.progressMirrorTask`) reads this from the MainActor on every tick, and
    /// blocking that on `engineQueue`'s FIFO — which can be busy decoding/scheduling a batch of
    /// frames — was the highest-ranked hang candidate in the audit. `cachedElapsedSeconds` is
    /// written from `engineQueue` (inside `schedule`, i.e. already serialised with engine mutation)
    /// and read from any thread under this tiny, always-uncontended lock instead.
    private let elapsedLock = NSLock()
    private var cachedElapsedSeconds: Double = 0
    private var generation: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return _generation
    }

    @discardableResult
    private func bumpGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        _generation += 1
        return _generation
    }

    /// LUFS loudness gain for Task A's per-song stream path (`progress/tvos-playback.md` "EQ/LUFS
    /// のルーティング判断" 追記). Linear gain (same `pow(10, dB/20)` formula and `0...4` clamp as
    /// `MusicPlayerService.applyLoudnessGain()`), applied to `mainMixerNode.outputVolume` — the
    /// relay path (continuous YouTube audio, already the host's own mix) has never needed this and
    /// stays at the default `1.0`. Full 10-band EQ is deliberately NOT replicated on this
    /// standalone engine; see the type doc comment's "EQ routing decision" for why.
    var outputGain: Float = 1.0 {
        didSet { applyOutputVolume() }
    }

    private func applyOutputVolume() {
        engine.mainMixerNode.outputVolume = muteOutput ? 0 : outputGain
    }

    /// - Parameter muteOutput: silences `mainMixerNode` (`outputVolume = 0`) so verification runs
    ///   (the `UXTV_PREVIEW=relay` DEBUG harness, and any future automated test that schedules
    ///   real PCM) never play audible sound through the host Mac's speakers. The
    ///   `[RelayStream] rendering rms=` log is computed from the decoded samples *before* they
    ///   reach the mixer (`logRMSIfDue`, called from `schedule` before the buffer is even built),
    ///   so muting the speaker output does not weaken that signal. Defaults to auto-detecting
    ///   `UXTV_PREVIEW`/`XCTestConfigurationFilePath` in the process environment so production
    ///   (real pairing flow) playback is never accidentally muted.
    init(
        jitterBufferSeconds: Double = 0.75,
        sessionConfiguration: URLSessionConfiguration = .default,
        muteOutput: Bool = TVRelayStreamPlayer.isRunningUnderPreviewOrTestHarness
    ) {
        self.jitterBufferSeconds = jitterBufferSeconds
        self.muteOutput = muteOutput
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 0 // long-lived stream
        self.session = URLSession(configuration: sessionConfiguration)
        super.init()
    }

    private static var isRunningUnderPreviewOrTestHarness: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["UXTV_PREVIEW"] != nil || env["XCTestConfigurationFilePath"] != nil
    }

    /// Starts streaming, parsing, decoding and playing `request`. Idempotent teardown is the
    /// caller's responsibility (`TVRelayPlaybackController` always calls `stop()` first).
    ///
    /// Deliberately `engineQueue.async`, not `.sync` (`progress/tvos-playback.md` "engineQueue↔
    /// MainActor デッドロック" 追記): the caller is always the MainActor (`TVSongStreamController`/
    /// `TVRelayPlaybackController`), and blocking it on `engineQueue` risked a hang if any
    /// AVAudioEngine call on that queue ever synchronously waited on the render thread or the
    /// MainActor. `generation` is bumped FIRST, synchronously, via the lock-guarded
    /// `bumpGeneration()` — not inside this block — so callers never need to wait for `engineQueue`
    /// just to make stale in-flight frames a no-op; only the actual `engine`/`playerNode` mutation
    /// is deferred onto the queue, and the serial queue's FIFO ordering (this player's own,
    /// per-instance) still totally orders it against any `stop()` issued just before.
    func start(request: URLRequest) {
        bumpGeneration()
        engineQueue.async { [self] in
            parser = ADTSFrameParser()
            decoder = nil
            didStartRendering = false
            bufferedSeconds = 0
            isEngineConnected = false
            refreshCachedElapsedSeconds()

            if !engine.attachedNodes.contains(playerNode) {
                engine.attach(playerNode)
            }
            applyOutputVolume()
            // Deliberately NOT connected here: `AVAudioEngine.connect(_:to:format:)` with `format:
            // nil` picks up whatever the node's default output format happens to be, which does not
            // match the stream's actual sample rate/channel count and previously caused a hard
            // `EXC_BAD_ACCESS` crash inside `AURemoteIO`'s render thread the moment a mismatched PCM
            // buffer was scheduled. The connection is made lazily in `schedule(_:format:channelCount:)`
            // once the real decoded format is known (from the ADTS header, so it never changes after).
        }

        task = session.dataTask(with: request)
        task?.delegate = self
        task?.resume()
    }

    /// Tears down the network task and the dedicated audio engine. Safe to call repeatedly.
    ///
    /// Deliberately `engineQueue.async`, not `.sync` — see `start()`'s doc comment for the
    /// MainActor-deadlock-avoidance rationale; the same applies here. `[self]` (a STRONG capture,
    /// not `[weak self]`) is intentional: the whole point of deferring is that the caller
    /// (`TVSongStreamController.teardown()`) drops its own reference to this player right after
    /// calling `stop()`, and a weak capture would let this object be deallocated before the
    /// enqueued teardown runs — silently skipping `engine.detach`/`.stop()` and leaking/reintroducing
    /// the exact torn-down-engine race this queue exists to prevent. The strong capture keeps the
    /// player alive just long enough for its own queued teardown to finish, then it is released
    /// normally. `generation` is bumped synchronously up front (see `bumpGeneration()`) so any frame
    /// already in flight on the delegate queue is discarded the moment it reaches `handle`/`schedule`,
    /// without needing to wait for this block to actually run.
    func stop() {
        task?.cancel()
        task = nil
        bumpGeneration()
        engineQueue.async { [self] in
            playerNode.stop()
            if engine.isRunning {
                engine.stop()
            }
            if engine.attachedNodes.contains(playerNode) {
                engine.detach(playerNode)
            }
            decoder = nil
            parser = ADTSFrameParser()
            didStartRendering = false
            bufferedSeconds = 0
            isEngineConnected = false
            refreshCachedElapsedSeconds()
        }
    }

    /// Approximate elapsed playback position, derived the same way as
    /// `MusicPlayerService.currentTimelineSeconds()` (`AVAudioPlayerNode.playerTime(forNodeTime:)`
    /// against the node's own render clock) — the only timeline available here since this is a
    /// live decoded stream, not a seekable file. `0` before playback has actually started
    /// (`didStartRendering`). Used by `TVSongStreamController`/`TVPlaybackController` to mirror
    /// progress into `MusicPlayerService.updateExternalPlaybackProgress` for `TVNowPlayingView`.
    var elapsedSeconds: Double {
        elapsedLock.lock()
        defer { elapsedLock.unlock() }
        return cachedElapsedSeconds
    }

    /// Recomputes `cachedElapsedSeconds` from the render clock. Always called from `engineQueue`
    /// (`schedule`, already serialised with engine mutation there) — never touches `engineQueue`
    /// itself, so it never contends with a busy decode/schedule backlog.
    private func refreshCachedElapsedSeconds() {
        var value: Double = 0
        if didStartRendering,
           let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime),
           playerTime.sampleRate > 0 {
            value = Double(playerTime.sampleTime) / playerTime.sampleRate
        }
        elapsedLock.lock()
        cachedElapsedSeconds = value
        elapsedLock.unlock()
    }

    /// Pauses playback in place (network keeps streaming/buffering in the background — this only
    /// stops the render, mirroring `MusicPlayerService.togglePlayPause()`'s local-file pause).
    ///
    /// Deliberately `engineQueue.async`, not `.sync` (`progress/tvos-playback-concurrency.md`):
    /// the caller is always the MainActor, and this is user-tap-triggered so there is no need to
    /// block it on the engine's own serial queue just to observe completion.
    func pause() {
        engineQueue.async { [self] in playerNode.pause() }
    }

    /// Resumes a paused stream. No-op if `stop()` has since torn the engine down. See `pause()`'s
    /// doc comment for why this is `.async`, not `.sync`.
    func resume() {
        engineQueue.async { [self] in
            guard engine.attachedNodes.contains(playerNode) else { return }
            if !engine.isRunning { try? engine.start() }
            playerNode.play()
        }
    }

    // MARK: - Frame handling

    /// Always invoked on `engineQueue` (from the delegate-queue dispatch in
    /// `urlSession(_:dataTask:didReceive:)`). `expectedGeneration` pins this closure to the
    /// session that scheduled it: if `stop()` bumped `generation` in the meantime, this is a
    /// stale chunk from a torn-down session and must not touch the engine.
    private func handle(_ frames: [ADTSFrame], expectedGeneration: Int) {
        guard !frames.isEmpty, expectedGeneration == generation else { return }

        if decoder == nil {
            do {
                decoder = try TVAACDecoder(header: frames[0].header)
            } catch {
                fail(reason: String(localized: "tv.relay.error.unknown"))
                return
            }
        }
        guard let decoder else { return }

        for frame in frames {
            guard expectedGeneration == generation else { return }
            let pcm: [Float]
            do {
                pcm = try decoder.decode(frame)
            } catch {
                continue // drop the bad frame; ADTS streams tolerate occasional frame loss
            }
            guard !pcm.isEmpty else { continue }
            schedule(pcm, format: decoder.outputFormat, channelCount: Int(decoder.channelCount))
        }
    }

    /// Always invoked on `engineQueue`, with `generation` already re-checked by the caller
    /// (`handle`) immediately before each call — never touches `engine`/`playerNode` for a
    /// session that `stop()` has since torn down.
    private func schedule(_ interleaved: [Float], format: AVAudioFormat, channelCount: Int) {
        let frameCount = interleaved.count / channelCount
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else { return }
        for frameIndex in 0..<frameCount {
            for channel in 0..<channelCount {
                channelData[channel][frameIndex] = interleaved[frameIndex * channelCount + channel]
            }
        }

        guard engine.attachedNodes.contains(playerNode) else { return }

        if !isEngineConnected {
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            isEngineConnected = true
        }
        if !engine.isRunning {
            try? engine.start()
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        bufferedSeconds += Double(frameCount) / format.sampleRate

        logRMSIfDue(interleaved)

        if !didStartRendering, bufferedSeconds >= jitterBufferSeconds {
            didStartRendering = true
            playerNode.play()
            let player = self
            DispatchQueue.main.async {
                player.delegate?.relayStreamPlayerDidStartRendering(player)
            }
        }
        refreshCachedElapsedSeconds()
    }

    #if DEBUG
    private func logRMSIfDue(_ samples: [Float]) {
        let now = Date()
        guard now.timeIntervalSince(lastRMSLogTime) >= 2 else { return }
        lastRMSLogTime = now
        let sumSquares = samples.reduce(Double(0)) { $0 + Double($1) * Double($1) }
        let rms = samples.isEmpty ? 0 : (sumSquares / Double(samples.count)).squareRoot()
        NSLog("[RelayStream] rendering rms=%.4f", rms)
    }
    #else
    private func logRMSIfDue(_ samples: [Float]) {}
    #endif

    private func fail(reason: String) {
        task?.cancel()
        task = nil
        let player = self
        DispatchQueue.main.async {
            player.delegate?.relayStreamPlayer(player, didFailWith: reason)
        }
    }
}

extension TVRelayStreamPlayer: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            fail(reason: String(localized: "tv.relay.error.unknown"))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Parsing (`parser.feed`) also touches engine-session state (`parser` is reset by both
        // `start()` and `stop()`), so it is dispatched onto `engineQueue` too rather than run
        // inline on the delegate queue — otherwise `parser.feed` here could race a concurrent
        // `parser = ADTSFrameParser()` reset from `stop()`/`start()` on the main thread.
        //
        // `capturedGeneration` MUST be read here, on the delegate queue, BEFORE dispatching onto
        // `engineQueue` — not inside the dispatched closure. `generation`'s getter/`bumpGeneration()`
        // are guarded by `generationLock`, not `engineQueue` (see that lock's doc comment), so
        // `start()`/`stop()` can bump it at any moment, including while this closure is sitting in
        // `engineQueue`'s backlog. Reading it up front captures "what session was this chunk sent
        // for", so a `stop()`/`start()` that happens before this closure gets its turn on
        // `engineQueue` (stress case: `TVPlaybackStressTests`'s rapid stop/restart churn, where
        // `engineQueue` can be backed up with several superseded sessions' worth of chunks) is
        // correctly detected as stale by `handle(_:expectedGeneration:)`. Capturing it INSIDE the
        // closure instead (the previous bug) reads the CURRENT generation at execution time, which
        // trivially always equals itself and defeats the staleness check entirely — stale frames
        // from a torn-down session would silently get fed into the NEW session's `parser`/`decoder`.
        let capturedGeneration = generation
        engineQueue.async { [weak self] in
            guard let self else { return }
            // Re-check on `engineQueue` itself, BEFORE touching `parser`: `parser` is a single
            // shared instance reset by `start()`/`stop()` (not one per session), so a stale chunk
            // fed into it here — even if `handle(_:expectedGeneration:)` would go on to discard the
            // resulting frames — has already corrupted the CURRENT session's byte-stream framing by
            // the time that discard happens (`TVPlaybackStressTests`'s rapid stop/restart churn
            // reliably produced silently-failing decodes this way before this guard existed: a
            // stale chunk's bytes got spliced into the new session's ADTS stream, desyncing frame
            // boundaries for everything after it). This is the one place a generation mismatch must
            // stop the chunk outright rather than merely skip the engine-touching part of `handle`.
            guard capturedGeneration == self.generation else { return }
            let frames = self.parser.feed(data)
            self.handle(frames, expectedGeneration: capturedGeneration)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            // Normal end of the HTTP body: for the finite per-song stream (Task A) this IS end of
            // track; the continuous relay stream never reaches this branch in practice.
            let player = self
            DispatchQueue.main.async {
                player.delegate?.relayStreamPlayerDidReachEndOfStream(player)
            }
            return
        }
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        fail(reason: error.localizedDescription)
    }
}
