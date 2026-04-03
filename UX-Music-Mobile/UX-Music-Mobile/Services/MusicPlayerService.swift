import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// Local playback with optional loudness normalisation (same idea as Flutter `MusicPlayerService`).
@MainActor
@Observable
final class MusicPlayerService {
    private let player = AVPlayer()

    private var queue: [Song] = []
    private var currentIndex: Int = -1

    /// Current playback queue (local files), in play order.
    var playbackQueue: [Song] { queue }
    /// Index of the current track in `playbackQueue`, or `-1` when idle.
    var currentQueueIndex: Int { currentIndex }
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeControlStatusObservation: NSKeyValueObservation?

    private(set) var currentSong: Song?
    private(set) var isPlaying = false
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0

    var loudnessMap: [String: Double] = [:]
    var targetLoudness: Double = AppConstants.defaultTargetLoudness
    var normaliseEnabled = true
    var masterVolume: Float = 1

    /// When set (by `AppModel`), jacket art is shown in Now Playing, Dynamic Island, and Control Centre.
    var loadArtworkImage: (@MainActor (Song) async -> UIImage?)?

    /// Audio session activation is deferred until playback starts to keep app launch light.
    private var playbackSessionPrepared = false
    /// In-flight activation so concurrent `play` / `toggle` callers share one `setActive` path.
    private var sessionActivationTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    private var lastPublishedNowPlayingSongId: String?
    private var artworkLoadedForSongId: String?
    private var artworkInFlightForSongId: String?
    private var nowPlayingArtworkImage: UIImage?

    init() {
        // Local files: avoid extra “wait for buffer” stall on first `play()` (still fine for on-disk media).
        player.automaticallyWaitsToMinimizeStalling = false
        addTimeObserver()
        timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.syncIsPlayingFromPlayer()
            }
        }
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
        installRemoteCommandHandlers()
        addAudioInterruptionObserver()
    }

    /// Configures and activates the shared session on the main actor. Apple documents that mutating
    /// `AVAudioSession` from a background queue yields undefined behaviour (often `setCategory` /
    /// `setActive` failures and stuck `AVPlayer` at 0:00 — e.g. `SessionCore` “Failed to set properties”).
    private func preparePlaybackSessionIfNeeded() async {
        if playbackSessionPrepared { return }
        if let sessionActivationTask {
            await sessionActivationTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: [.allowBluetoothA2DP, .allowAirPlay]
                )
                try session.setActive(true, options: [])
                self.playbackSessionPrepared = true
            } catch {
                #if DEBUG
                NSLog("UXMusic: AVAudioSession setup failed: \(error)")
                #endif
            }
        }
        sessionActivationTask = task
        await task.value
        sessionActivationTask = nil
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
                self.syncIsPlayingFromPlayer()
                self.updateNowPlayingCentre()
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.preparePlaybackSessionIfNeeded()
            switch self.player.timeControlStatus {
            case .playing, .waitingToPlayAtSpecifiedRate:
                self.player.pause()
            case .paused:
                self.player.play()
            @unknown default:
                if self.player.rate > 0.01 {
                    self.player.pause()
                } else {
                    self.player.play()
                }
            }
            self.syncIsPlayingFromPlayer()
            self.updateNowPlayingCentre()
        }
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

    /// Jumps to a track already present in the queue and starts playback.
    func playQueueItem(at index: Int) async {
        guard index >= 0, index < queue.count else { return }
        currentIndex = index
        let s = queue[currentIndex]
        currentSong = s
        await loadAndPlay(s)
    }

    func seek(to seconds: Double) async {
        let t = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        await player.seek(to: t)
        positionSeconds = seconds
        updateNowPlayingCentre()
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
        lastPublishedNowPlayingSongId = nil
        artworkLoadedForSongId = nil
        artworkInFlightForSongId = nil
        nowPlayingArtworkImage = nil
        updateNowPlayingCentre()
    }

    private func loadAndPlay(_ song: Song) async {
        await preparePlaybackSessionIfNeeded()
        await Task.yield()
        let url = URL(fileURLWithPath: song.path)
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )

        // Heavy format probe / decoder setup runs in the asset loader; each `await` suspends without blocking the UI thread.
        var loadedDuration: Double = 0
        do {
            _ = try await asset.load(.isPlayable)
        } catch {
            // Decoder may still succeed once the item is attached.
        }
        do {
            let d = try await asset.load(.duration)
            if d.seconds.isFinite, d.seconds > 0 {
                loadedDuration = d.seconds
            }
        } catch {
            // Duration may appear later via the periodic observer.
        }
        durationSeconds = loadedDuration

        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        applyLoudnessGain()
        if loadedDuration == 0 {
            Task { [weak self] in
                guard let self else { return }
                if let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 {
                    await MainActor.run {
                        self.durationSeconds = d.seconds
                        self.updateNowPlayingCentre()
                    }
                }
            }
        }
        await Task.yield()
        player.play()
        syncIsPlayingFromPlayer()
        updateNowPlayingCentre()
    }

    private func syncIsPlayingFromPlayer() {
        let next = PlaybackControlState.showsPauseButton(
            timeControlStatus: player.timeControlStatus,
            rate: player.rate
        )
        guard next != isPlaying else { return }
        isPlaying = next
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

    // MARK: - Lock screen / Control Centre / background session

    private func installRemoteCommandHandlers() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.preparePlaybackSessionIfNeeded()
                self.player.play()
                self.syncIsPlayingFromPlayer()
                self.updateNowPlayingCentre()
            }
            return .success
        }

        c.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.player.pause()
                self.syncIsPlayingFromPlayer()
                self.updateNowPlayingCentre()
            }
            return .success
        }

        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.togglePlayPause()
            }
            return .success
        }

        c.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.next()
            }
            return .success
        }

        c.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.previous()
            }
            return .success
        }

        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let ev = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                await self.seek(to: ev.positionTime)
            }
            return .success
        }
    }

    private func updateNowPlayingCentre() {
        let c = MPRemoteCommandCenter.shared()
        let active = currentSong != nil
        c.playCommand.isEnabled = active
        c.pauseCommand.isEnabled = active
        c.togglePlayPauseCommand.isEnabled = active
        c.nextTrackCommand.isEnabled = active && queue.count > 1
        c.previousTrackCommand.isEnabled = active && queue.count > 1
        c.changePlaybackPositionCommand.isEnabled = active

        guard let song = currentSong else {
            lastPublishedNowPlayingSongId = nil
            artworkLoadedForSongId = nil
            artworkInFlightForSongId = nil
            nowPlayingArtworkImage = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        let songChanged = lastPublishedNowPlayingSongId != song.id
        if songChanged {
            lastPublishedNowPlayingSongId = song.id
            artworkLoadedForSongId = nil
            artworkInFlightForSongId = nil
            nowPlayingArtworkImage = nil
        }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if songChanged {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
        }

        let fromMetadata = song.duration > 0 ? song.duration : 0
        let effectiveDuration = max(durationSeconds, fromMetadata)
        let durationForInfo = max(effectiveDuration, 0.001)

        info[MPMediaItemPropertyTitle] = song.displayTitle
        info[MPMediaItemPropertyArtist] = song.displayArtist
        info[MPMediaItemPropertyAlbumTitle] = song.displayAlbum
        info[MPMediaItemPropertyPlaybackDuration] = durationForInfo
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, positionSeconds)
        info[MPNowPlayingInfoPropertyPlaybackRate] = Double(player.rate)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        if info[MPMediaItemPropertyArtwork] == nil,
           let img = nowPlayingArtworkImage,
           artworkLoadedForSongId == song.id {
            info[MPMediaItemPropertyArtwork] = makeMediaArtwork(from: img)
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if loadArtworkImage != nil,
           artworkLoadedForSongId != song.id,
           artworkInFlightForSongId != song.id {
            ensureArtworkLoaded(for: song)
        }
    }

    private func ensureArtworkLoaded(for song: Song) {
        guard loadArtworkImage != nil else { return }
        if artworkLoadedForSongId == song.id { return }
        if artworkInFlightForSongId == song.id { return }
        artworkInFlightForSongId = song.id
        let songId = song.id
        Task { @MainActor in
            defer {
                if self.artworkInFlightForSongId == songId {
                    self.artworkInFlightForSongId = nil
                }
            }
            guard let loader = self.loadArtworkImage else { return }
            let image = await loader(song)
            guard self.currentSong?.id == songId else { return }
            self.artworkLoadedForSongId = songId
            self.nowPlayingArtworkImage = image
            self.updateNowPlayingCentre()
        }
    }

    private func makeMediaArtwork(from image: UIImage) -> MPMediaItemArtwork {
        let longest = max(image.size.width, image.size.height)
        let side = max(256, min(1024, longest))
        let boundsSize = CGSize(width: side, height: side)
        return MPMediaItemArtwork(boundsSize: boundsSize) { requestedSize in
            let w = max(requestedSize.width, 1)
            let h = max(requestedSize.height, 1)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
            return renderer.image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
    }

    private func addAudioInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let info = notification.userInfo,
                let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
            else { return }

            Task { @MainActor in
                switch type {
                case .began:
                    self.player.pause()
                    self.syncIsPlayingFromPlayer()
                case .ended:
                    if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                        let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                        if opts.contains(.shouldResume) {
                            try? AVAudioSession.sharedInstance().setActive(true)
                            self.player.play()
                            self.syncIsPlayingFromPlayer()
                        }
                    }
                @unknown default:
                    break
                }
                self.updateNowPlayingCentre()
            }
        }
    }
}
