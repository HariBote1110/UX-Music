import AVFoundation
import Foundation
import WatchKit

/// AVPlayer-backed playback service for the Watch app. Mirrors the reference implementation in
/// standalone watch playback: `.playback`
/// `AVAudioSession` category plus a `WKExtendedRuntimeSession` so audio keeps playing once the
/// screen locks or the wrist drops.
@MainActor
final class WatchAudioPlayerService: NSObject, ObservableObject {

    @Published var currentSong: WatchTransferMeta?
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var volume: Double = 0.7 {
        didSet { player?.volume = Float(volume) }
    }

    private var player: AVPlayer?
    private var queue: [WatchTransferMeta] = []
    private var currentIndex = 0
    private var timeObserver: Any?
    private var runtimeSession: WKExtendedRuntimeSession?
    private let library: WatchLocalLibrary

    init(library: WatchLocalLibrary) {
        self.library = library
    }

    func play(_ song: WatchTransferMeta, queue songs: [WatchTransferMeta]) {
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
        if position > 3 {
            player?.seek(to: .zero)
        } else {
            guard !queue.isEmpty else { return }
            currentIndex = (currentIndex - 1 + queue.count) % queue.count
            load(queue[currentIndex])
        }
    }

    private func load(_ song: WatchTransferMeta) {
        clearPlayer()
        currentSong = song

        let url = library.audioFileURL(for: song)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[WatchAudioPlayer] File not found: \(url.path)")
            return
        }

        configureAudioSession()
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.volume = Float(volume)
        avPlayer.play()
        isPlaying = true
        player = avPlayer

        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.position = time.seconds
        }

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
            print("[WatchAudioPlayer] AVAudioSession error: \(error)")
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

    /// Keeps audio playing in the background (screen off / wrist down) for as long as watchOS grants.
    private func startExtendedRuntime() {
        runtimeSession?.invalidate()
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        runtimeSession = session
    }
}

extension WatchAudioPlayerService: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    nonisolated func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {}
}
