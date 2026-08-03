import AVFoundation
import Foundation
import MediaPlayer
import WatchKit

/// AVPlayer-backed playback service for the Watch app. Mirrors the reference implementation in
/// standalone watch playback: `.playback`
/// `AVAudioSession` category plus a `WKExtendedRuntimeSession` so audio keeps playing once the
/// screen locks or the wrist drops.
///
/// System integration: publishes state to `MPNowPlayingInfoCenter` and wires
/// `MPRemoteCommandCenter` (play/pause/next/previous) so the standard watchOS "Now Playing" glance,
/// AirPods controls, and the paired iPhone's control centre all reflect and drive this player.
@MainActor
final class WatchAudioPlayerService: NSObject, ObservableObject {

    @Published var currentSong: WatchTransferMeta?
    @Published var isPlaying = false
    @Published var position: Double = 0

    private var player: AVPlayer?
    private var queue: [WatchTransferMeta] = []
    private var currentIndex = 0
    private var timeObserver: Any?
    private var runtimeSession: WKExtendedRuntimeSession?
    private let library: WatchLocalLibrary

    init(library: WatchLocalLibrary) {
        self.library = library
        super.init()
        configureRemoteCommands()
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
        updateNowPlayingInfo()
    }

    func next() {
        guard !queue.isEmpty else { return }
        currentIndex = WatchQueueNavigation.nextIndex(current: currentIndex, count: queue.count)
        load(queue[currentIndex])
    }

    func previous() {
        if WatchQueueNavigation.shouldRestartOnPrevious(position: position) {
            seek(to: 0)
        } else {
            guard !queue.isEmpty else { return }
            currentIndex = WatchQueueNavigation.previousIndex(current: currentIndex, count: queue.count)
            load(queue[currentIndex])
        }
    }

    /// Seeks to `seconds`, clamped to the current track's duration (see `WatchSeekLogic`). Driven
    /// by the Digital Crown on `WatchNowPlayingView` since dragging a slider is impractical on
    /// watchOS.
    func seek(to seconds: Double) {
        let duration = currentSong?.duration ?? 0
        let clamped = WatchSeekLogic.clampedPosition(seconds, duration: duration)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        position = clamped
        updateNowPlayingInfo()
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
        avPlayer.play()
        isPlaying = true
        player = avPlayer

        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.position = time.seconds
            self?.updateNowPlayingInfo()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        updateNowPlayingInfo()
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

    /// Publishes the current track/position/rate to `MPNowPlayingInfoCenter` so watchOS's system
    /// "Now Playing" surface (and the paired iPhone) reflect what is actually playing.
    private func updateNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = WatchNowPlayingInfoBuilder.buildInfo(
            for: currentSong,
            isPlaying: isPlaying,
            position: position
        )
    }

    /// Wires `MPRemoteCommandCenter` so play/pause/next/previous from AirPods, the watch's system
    /// Now Playing glance, or the paired iPhone drive this player.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player, !self.isPlaying else { return .commandFailed }
            player.play()
            self.isPlaying = true
            self.updateNowPlayingInfo()
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, let player = self.player, self.isPlaying else { return .commandFailed }
            player.pause()
            self.isPlaying = false
            self.updateNowPlayingInfo()
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }

        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
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
