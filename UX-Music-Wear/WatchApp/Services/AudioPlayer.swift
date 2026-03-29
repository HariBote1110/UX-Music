import Foundation
import AVFoundation
import WatchKit

@MainActor
final class AudioPlayerService: NSObject, ObservableObject {

    @Published var currentSong: Song?
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var volume: Double = 0.7 {
        didSet { player?.volume = Float(volume) }
    }

    private var player: AVPlayer?
    private var queue: [Song] = []
    private var currentIndex: Int = 0
    private var timeObserver: Any?
    private var runtimeSession: WKExtendedRuntimeSession?

    // MARK: - Public API

    func play(_ song: Song, queue songs: [Song]) {
        queue = songs
        currentIndex = songs.firstIndex(where: { $0.id == song.id }) ?? 0
        load(song)
        startExtendedRuntime()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func next() {
        guard !queue.isEmpty else { return }
        currentIndex = (currentIndex + 1) % queue.count
        load(queue[currentIndex])
    }

    func previous() {
        // Restart if more than 3 seconds in, else go to previous
        if position > 3 {
            player?.seek(to: .zero)
        } else {
            guard !queue.isEmpty else { return }
            currentIndex = (currentIndex - 1 + queue.count) % queue.count
            load(queue[currentIndex])
        }
    }

    // MARK: - Private

    private func load(_ song: Song) {
        clearPlayer()
        currentSong = song

        let url = LocalLibrary.fileURL(for: song)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[AudioPlayer] File not found: \(url.path)")
            return
        }

        configureAudioSession()
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.volume = Float(volume)
        avPlayer.play()
        isPlaying = true
        player = avPlayer

        // Position tracking
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.position = time.seconds
        }

        // Auto-advance
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioPlayer] AVAudioSession error: \(error)")
        }
    }

    private func clearPlayer() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        player?.pause()
        player = nil
        position = 0
    }

    @objc private func itemDidFinish() {
        next()
    }

    // MARK: - Extended Runtime (background playback while screen is off)

    private func startExtendedRuntime() {
        runtimeSession?.invalidate()
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        runtimeSession = session
    }
}

// MARK: - WKExtendedRuntimeSessionDelegate

extension AudioPlayerService: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("[AudioPlayer] Extended runtime started")
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("[AudioPlayer] Extended runtime will expire")
    }

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        print("[AudioPlayer] Extended runtime invalidated: \(reason.rawValue)")
    }
}
