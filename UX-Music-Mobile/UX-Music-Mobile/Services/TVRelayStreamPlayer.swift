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
final class TVRelayStreamPlayer: NSObject {
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
    func start(request: URLRequest) {
        parser = ADTSFrameParser()
        decoder = nil
        didStartRendering = false
        bufferedSeconds = 0
        isEngineConnected = false

        engine.attach(playerNode)
        applyOutputVolume()
        // Deliberately NOT connected here: `AVAudioEngine.connect(_:to:format:)` with `format:
        // nil` picks up whatever the node's default output format happens to be, which does not
        // match the stream's actual sample rate/channel count and previously caused a hard
        // `EXC_BAD_ACCESS` crash inside `AURemoteIO`'s render thread the moment a mismatched PCM
        // buffer was scheduled. The connection is made lazily in `schedule(_:format:channelCount:)`
        // once the real decoded format is known (from the ADTS header, so it never changes after).

        task = session.dataTask(with: request)
        task?.delegate = self
        task?.resume()
    }

    /// Tears down the network task and the dedicated audio engine. Safe to call repeatedly.
    func stop() {
        task?.cancel()
        task = nil
        playerNode.stop()
        engine.stop()
        if engine.attachedNodes.contains(playerNode) {
            engine.detach(playerNode)
        }
        decoder = nil
        parser = ADTSFrameParser()
        didStartRendering = false
        bufferedSeconds = 0
        isEngineConnected = false
    }

    // MARK: - Frame handling

    private func handle(_ frames: [ADTSFrame]) {
        guard !frames.isEmpty else { return }

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
        let frames = parser.feed(data)
        handle(frames)
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
