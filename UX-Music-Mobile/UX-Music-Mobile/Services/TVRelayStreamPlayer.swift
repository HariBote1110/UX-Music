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

    init(jitterBufferSeconds: Double = 0.75, sessionConfiguration: URLSessionConfiguration = .default) {
        self.jitterBufferSeconds = jitterBufferSeconds
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 0 // long-lived stream
        self.session = URLSession(configuration: sessionConfiguration)
        super.init()
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
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        fail(reason: error.localizedDescription)
    }
}
