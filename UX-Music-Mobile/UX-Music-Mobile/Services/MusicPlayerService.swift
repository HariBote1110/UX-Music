import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// Local playback with optional loudness normalisation and 10-band graphic EQ (`AVAudioEngine` + `AVAudioUnitEQ`).
@MainActor
@Observable
final class MusicPlayerService {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let eqUnit = AVAudioUnitEQ(numberOfBands: EqualiserConstants.bandCount)

    private var queue: [Song] = []
    private var currentIndex: Int = -1

    private var audioFile: AVAudioFile?
    private var connectionFormat: AVAudioFormat?
    private var graphInstalled = false
    /// File frame index where the currently scheduled segment begins (seek / position).
    private var segmentStartFileFrame: AVAudioFramePosition = 0

    private var positionTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?

    private var routeGeneration: UInt64 = 0

    /// Current playback queue (local files), in play order.
    var playbackQueue: [Song] { queue }
    /// Index of the current track in `playbackQueue`, or `-1` when idle.
    var currentQueueIndex: Int { currentIndex }

    private(set) var currentSong: Song?
    private(set) var isPlaying = false
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0

    var loudnessMap: [String: Double] = [:]
    var targetLoudness: Double = AppConstants.defaultTargetLoudness
    var normaliseEnabled = true
    var masterVolume: Float = 1

    /// Read on each `applyEqualiserCurve()` / `refreshEqualiser()`.
    var equaliserCurveProvider: () -> EqualiserCurve = { .disabled }

    /// When set (by `AppModel`), jacket art is shown in Now Playing, Dynamic Island, and Control Centre.
    var loadArtworkImage: (@MainActor (Song) async -> UIImage?)?

    private var playbackSessionPrepared = false
    private var sessionActivationTask: Task<Void, Never>?

    private var lastPublishedNowPlayingSongId: String?
    private var artworkLoadedForSongId: String?
    private var artworkInFlightForSongId: String?
    private var nowPlayingArtworkImage: UIImage?

    init() {
        prepareEqualiserStaticBands()
        addAudioInterruptionObserver()
        installRemoteCommandHandlers()
    }

    private func prepareEqualiserStaticBands() {
        let freqs = EqualiserConstants.centreFrequenciesHz
        guard eqUnit.bands.count == freqs.count else { return }
        for (i, band) in eqUnit.bands.enumerated() {
            band.frequency = freqs[i]
            if i == 0 {
                band.filterType = .lowShelf
            } else if i == EqualiserConstants.bandCount - 1 {
                band.filterType = .highShelf
            } else {
                band.filterType = .parametric
                band.bandwidth = 1
            }
            band.bypass = false
            band.gain = 0
        }
    }

    private func ensureGraphInstalled() {
        guard !graphInstalled else { return }
        engine.attach(playerNode)
        engine.attach(eqUnit)
        graphInstalled = true
    }

    private func connectGraph(for file: AVAudioFile) throws {
        let fmt = file.processingFormat
        if let connectionFormat, connectionFormat.isEqual(fmt) { return }
        if connectionFormat != nil {
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(eqUnit)
        }
        engine.connect(playerNode, to: eqUnit, format: fmt)
        engine.connect(eqUnit, to: engine.mainMixerNode, format: fmt)
        connectionFormat = fmt
    }

    private func ensureEngineRunning(with file: AVAudioFile) throws {
        ensureGraphInstalled()
        try connectGraph(for: file)
        applyEqualiserCurve()
        applyLoudnessGain()
        if !engine.isRunning {
            try engine.start()
        }
    }

    func refreshEqualiser() {
        applyEqualiserCurve()
    }

    private func applyEqualiserCurve() {
        let curve = equaliserCurveProvider()
        guard eqUnit.bands.count == EqualiserConstants.bandCount else { return }
        if !curve.isEnabled {
            eqUnit.auAudioUnit.shouldBypassEffect = true
            eqUnit.globalGain = 0
            for band in eqUnit.bands {
                band.gain = 0
            }
            return
        }
        eqUnit.auAudioUnit.shouldBypassEffect = false
        eqUnit.globalGain = curve.preampDb
        for (i, band) in eqUnit.bands.enumerated() {
            band.bypass = false
            band.gain = curve.bandGainsDb[i]
        }
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPosition() }
        }
        RunLoop.main.add(t, forMode: .common)
        positionTimer = t
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func tickPosition() {
        guard playerNode.isPlaying, audioFile != nil else { return }
        guard let nodeTime = playerNode.lastRenderTime,
              let pt = playerNode.playerTime(forNodeTime: nodeTime) else { return }
        let sr = pt.sampleRate
        guard sr > 0 else { return }
        let st = pt.sampleTime
        guard st >= 0 else { return }
        let elapsedFrames = Double(segmentStartFileFrame) + Double(st)
        let pos = elapsedFrames / sr
        let dur = durationSeconds
        positionSeconds = min(max(0, pos), dur > 0 ? dur : pos)
        updateNowPlayingCentre()
        syncIsPlayingFromNode()
    }

    private func syncIsPlayingFromNode() {
        let next = playerNode.isPlaying
        guard next != isPlaying else { return }
        isPlaying = next
    }

    private func preparePlaybackSessionIfNeeded() async {
        if playbackSessionPrepared { return }
        if let sessionActivationTask {
            await sessionActivationTask.value
            return
        }
        let task = Task<Void, Never> {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let session = AVAudioSession.sharedInstance()
                    try? session.setCategory(
                        .playback,
                        mode: .default,
                        options: [.allowBluetoothA2DP, .allowAirPlay]
                    )
                    try? session.setActive(true)
                    continuation.resume()
                }
            }
        }
        sessionActivationTask = task
        await task.value
        sessionActivationTask = nil
        playbackSessionPrepared = true
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
            if self.playerNode.isPlaying {
                self.playerNode.pause()
            } else {
                self.playerNode.play()
            }
            self.syncIsPlayingFromNode()
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

    func playQueueItem(at index: Int) async {
        guard index >= 0, index < queue.count else { return }
        currentIndex = index
        let s = queue[currentIndex]
        currentSong = s
        await loadAndPlay(s)
    }

    func seek(to seconds: Double) async {
        guard let file = audioFile else { return }
        let sr = file.fileFormat.sampleRate
        guard sr > 0 else { return }
        let target = AVAudioFramePosition(seconds * sr)
        let maxStart = max(0, file.length - 1)
        segmentStartFileFrame = min(max(0, target), maxStart)
        positionSeconds = min(max(0, seconds), durationSeconds > 0 ? durationSeconds : seconds)
        playerNode.stop()
        applyEqualiserCurve()
        applyLoudnessGain()
        scheduleRemaining(of: file)
        playerNode.play()
        syncIsPlayingFromNode()
        updateNowPlayingCentre()
    }

    func stop() {
        routeGeneration += 1
        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        stopPositionTimer()
        audioFile = nil
        currentSong = nil
        currentIndex = -1
        queue = []
        isPlaying = false
        positionSeconds = 0
        durationSeconds = 0
        segmentStartFileFrame = 0
        lastPublishedNowPlayingSongId = nil
        artworkLoadedForSongId = nil
        artworkInFlightForSongId = nil
        nowPlayingArtworkImage = nil
        updateNowPlayingCentre()
    }

    private func loadAndPlay(_ song: Song) async {
        routeGeneration += 1
        let token = routeGeneration

        await preparePlaybackSessionIfNeeded()
        guard token == routeGeneration else { return }
        await Task.yield()
        guard token == routeGeneration else { return }

        let url = URL(fileURLWithPath: song.path)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            durationSeconds = 0
            return
        }
        guard token == routeGeneration else { return }

        audioFile = file
        segmentStartFileFrame = 0

        let sr = file.fileFormat.sampleRate
        let len = file.length
        durationSeconds = sr > 0 ? Double(len) / sr : 0

        do {
            try ensureEngineRunning(with: file)
        } catch {
            return
        }
        guard token == routeGeneration else { return }

        playerNode.stop()
        applyEqualiserCurve()
        applyLoudnessGain()
        scheduleRemaining(of: file)
        playerNode.play()
        startPositionTimer()
        syncIsPlayingFromNode()
        updateNowPlayingCentre()
    }

    private func scheduleRemaining(of file: AVAudioFile) {
        let start = segmentStartFileFrame
        let total = file.length
        guard start < total else { return }
        let remaining = total - start
        let count = AVAudioFrameCount(remaining)
        playerNode.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil) { [weak self] in
            Task { @MainActor in await self?.advanceAfterEnd() }
        }
    }

    private func advanceAfterEnd() async {
        guard queue.count > 1 else { return }
        await next()
    }

    private func applyLoudnessGain() {
        guard normaliseEnabled, let id = currentSong?.id else {
            engine.mainMixerNode.outputVolume = masterVolume
            return
        }
        guard let lufs = loudnessMap[id] else {
            engine.mainMixerNode.outputVolume = masterVolume
            return
        }
        let gainDb = targetLoudness - lufs
        let linear = pow(10, gainDb / 20)
        let clamped = min(max(linear, 0), 4)
        engine.mainMixerNode.outputVolume = masterVolume * Float(clamped)
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
                self.playerNode.play()
                self.syncIsPlayingFromNode()
                self.updateNowPlayingCentre()
            }
            return .success
        }

        c.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.playerNode.pause()
                self.syncIsPlayingFromNode()
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
        info[MPNowPlayingInfoPropertyPlaybackRate] = playerNode.isPlaying ? 1.0 : 0.0
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
                    self.playerNode.pause()
                    self.syncIsPlayingFromNode()
                case .ended:
                    if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                        let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                        if opts.contains(.shouldResume) {
                            try? AVAudioSession.sharedInstance().setActive(true)
                            self.playerNode.play()
                            self.syncIsPlayingFromNode()
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
