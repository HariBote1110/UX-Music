import AVFoundation
import Foundation
import Observation

/// Local playback with optional loudness normalisation (same idea as Flutter `MusicPlayerService`).
@MainActor
@Observable
final class MusicPlayerService {
    private let player = AVPlayer()

    private var queue: [Song] = []
    private var currentIndex: Int = -1
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private(set) var currentSong: Song?
    private(set) var isPlaying = false
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0

    var loudnessMap: [String: Double] = [:]
    var targetLoudness: Double = AppConstants.defaultTargetLoudness
    var normaliseEnabled = true
    var masterVolume: Float = 1

    /// Audio session activation is deferred until playback starts to keep app launch light.
    private var playbackSessionPrepared = false

    init() {
        addTimeObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] n in
            guard let self else { return }
            if (n.object as? AVPlayerItem) === self.player.currentItem {
                Task { @MainActor in await self.advanceAfterEnd() }
            }
        }
    }

    private func ensurePlaybackSessionIfNeeded() {
        guard !playbackSessionPrepared else { return }
        playbackSessionPrepared = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            guard let self else { return }
            Task { @MainActor in
                self.positionSeconds = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                    self.durationSeconds = d
                }
                self.isPlaying = self.player.rate > 0.01
            }
        }
    }

    func play(_ song: Song, newQueue: [Song]?) async {
        if let newQueue {
            queue = newQueue
        }
        if let idx = queue.firstIndex(where: { $0.id == song.id }) {
            currentIndex = idx
        } else {
            queue.append(song)
            currentIndex = queue.count - 1
        }
        let active = queue[currentIndex]
        currentSong = active
        await loadAndPlay(active)
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            ensurePlaybackSessionIfNeeded()
            player.play()
        }
        isPlaying = player.rate > 0.01
    }

    func next() async {
        guard !queue.isEmpty else { return }
        currentIndex = (currentIndex + 1) % queue.count
        let s = queue[currentIndex]
        currentSong = s
        await loadAndPlay(s)
    }

    func previous() async {
        guard !queue.isEmpty else { return }
        if positionSeconds > 3 {
            await seek(to: 0)
        } else {
            currentIndex = (currentIndex - 1 + queue.count) % queue.count
            let s = queue[currentIndex]
            currentSong = s
            await loadAndPlay(s)
        }
    }

    func seek(to seconds: Double) async {
        let t = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        await player.seek(to: t)
        positionSeconds = seconds
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentSong = nil
        currentIndex = -1
        queue = []
        isPlaying = false
        positionSeconds = 0
        durationSeconds = 0
    }

    private func loadAndPlay(_ song: Song) async {
        ensurePlaybackSessionIfNeeded()
        let url = URL(fileURLWithPath: song.path)
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        applyLoudnessGain()
        durationSeconds = 0
        Task { [weak self] in
            guard let self else { return }
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
                await MainActor.run { self.durationSeconds = d.seconds }
            }
        }
        player.play()
        isPlaying = true
    }

    private func advanceAfterEnd() async {
        guard queue.count > 1 else { return }
        await next()
    }

    private func applyLoudnessGain() {
        guard normaliseEnabled, let id = currentSong?.id else {
            player.volume = masterVolume
            return
        }
        guard let lufs = loudnessMap[id] else {
            player.volume = masterVolume
            return
        }
        let gainDb = targetLoudness - lufs
        let linear = pow(10, gainDb / 20)
        let clamped = min(max(linear, 0), 4)
        player.volume = masterVolume * Float(clamped)
    }

    func refreshVolumeForCurrentSong() {
        applyLoudnessGain()
    }
}
