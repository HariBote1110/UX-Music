import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

/// Local playback with optional loudness normalisation and a 10-band graphic equaliser (`AVAudioEngine` + `AVAudioUnitEQ`).
@MainActor
@Observable
final class MusicPlayerService {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let equaliserUnit = AVAudioUnitEQ(numberOfBands: GraphicEqualiserConfiguration.bandCount)

    private var queue: [Song] = []
    private var currentIndex: Int = -1

    /// Current playback queue (local files), in play order.
    var playbackQueue: [Song] { queue }
    /// Index of the current track in `playbackQueue`, or `-1` when idle.
    var currentQueueIndex: Int { currentIndex }

    private var positionTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?

    private(set) var currentSong: Song?
    private(set) var isPlaying = false
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0

    var loudnessMap: [String: Double] = [:]
    var targetLoudness: Double = AppConstants.defaultTargetLoudness
    var normaliseEnabled = true
    var masterVolume: Float = 1

    // MARK: - Equaliser (persisted)

    private(set) var equaliserEnabled = false
    private(set) var equaliserPreampDecibels: Float = 0
    private(set) var equaliserBandDecibels: [Float] = Array(repeating: 0, count: GraphicEqualiserConfiguration.bandCount)
    /// Last applied preset label for UI; `"Custom"` when bands were edited manually.
    private(set) var equaliserPresetDisplayName: String = "Flat"

    private var isRestoringEqualiserState = false
    private let eqDefaultsKeyEnabled = "uxmusic.equaliser.enabled"
    private let eqDefaultsKeyPreamp = "uxmusic.equaliser.preamp"
    private let eqDefaultsKeyBands = "uxmusic.equaliser.bands"
    private let eqDefaultsKeyPreset = "uxmusic.equaliser.presetName"

    /// When set (by `AppModel`), jacket art is shown in Now Playing, Dynamic Island, and Control Centre.
    var loadArtworkImage: (@MainActor (Song) async -> UIImage?)?

    /// Audio session activation is deferred until playback starts to keep app launch light.
    private var playbackSessionPrepared = false
    /// In-flight activation so concurrent `play` / `toggle` callers share one `setActive` path.
    private var sessionActivationTask: Task<Void, Never>?

    private var lastPublishedNowPlayingSongId: String?
    private var artworkLoadedForSongId: String?
    private var artworkInFlightForSongId: String?
    private var nowPlayingArtworkImage: UIImage?

    // MARK: - Engine graph / timeline

    private var currentAudioFile: AVAudioFile?
    private var scheduledSegmentStartFrame: AVAudioFramePosition = 0
    private var frozenPositionWhilePaused: Double?
    private var lastWireFormat: AVAudioFormat?
    private var nodesAttached = false

    init() {
        configureEqualiserBandsStatically()
        pushEqualiserToAudioUnit()
        loadEqualiserStateFromUserDefaults()
        startPositionTimer()
        addAudioInterruptionObserver()
        installRemoteCommandHandlers()
    }

    // MARK: - Equaliser API

    func setEqualiserEnabled(_ active: Bool) {
        guard active != equaliserEnabled else { return }
        equaliserEnabled = active
        touchEqualiserPersistAndAudio()
    }

    func setEqualiserPreampDecibels(_ value: Float) {
        let clamped = GraphicEqualiserConfiguration.clampedDecibel(value)
        guard clamped != equaliserPreampDecibels else { return }
        equaliserPreampDecibels = clamped
        touchEqualiserPersistAndAudio()
    }

    func setEqualiserBand(index: Int, decibels: Float) {
        guard equaliserBandDecibels.indices.contains(index) else { return }
        let clamped = GraphicEqualiserConfiguration.clampedDecibel(decibels)
        guard clamped != equaliserBandDecibels[index] else { return }
        var next = equaliserBandDecibels
        next[index] = clamped
        equaliserBandDecibels = next
        equaliserPresetDisplayName = "Custom"
        touchEqualiserPersistAndAudio()
    }

    func applyEqualiserPreset(named name: String) {
        guard let bands = GraphicEqualiserConfiguration.bands(forPresetNamed: name) else { return }
        equaliserBandDecibels = bands
        equaliserPresetDisplayName = name
        touchEqualiserPersistAndAudio()
    }

    func resetEqualiserToFlat() {
        applyEqualiserPreset(named: "Flat")
        equaliserPreampDecibels = 0
        persistEqualiserState()
        pushEqualiserToAudioUnit()
    }

    private func configureEqualiserBandsStatically() {
        let hzList = GraphicEqualiserConfiguration.centreFrequenciesHz
        for i in 0 ..< GraphicEqualiserConfiguration.bandCount {
            let band = equaliserUnit.bands[i]
            band.frequency = hzList[i]
            band.gain = 0
            if i == 0 {
                band.filterType = .lowShelf
            } else if i == GraphicEqualiserConfiguration.bandCount - 1 {
                band.filterType = .highShelf
            } else {
                band.filterType = .parametric
                band.bandwidth = GraphicEqualiserConfiguration.parametricBandwidthOctaves
            }
        }
    }

    private func pushEqualiserToAudioUnit() {
        if equaliserEnabled {
            equaliserUnit.bypass = false
            equaliserUnit.globalGain = equaliserPreampDecibels
            for i in 0 ..< GraphicEqualiserConfiguration.bandCount {
                let b = equaliserUnit.bands[i]
                b.bypass = false
                b.gain = equaliserBandDecibels[i]
            }
        } else {
            equaliserUnit.globalGain = 0
            equaliserUnit.bypass = true
            for i in 0 ..< GraphicEqualiserConfiguration.bandCount {
                let b = equaliserUnit.bands[i]
                b.bypass = true
                b.gain = 0
            }
        }
    }

    private func touchEqualiserPersistAndAudio() {
        guard !isRestoringEqualiserState else { return }
        persistEqualiserState()
        pushEqualiserToAudioUnit()
    }

    private func persistEqualiserState() {
        guard !isRestoringEqualiserState else { return }
        let defaults = UserDefaults.standard
        defaults.set(equaliserEnabled, forKey: eqDefaultsKeyEnabled)
        defaults.set(equaliserPreampDecibels, forKey: eqDefaultsKeyPreamp)
        defaults.set(equaliserPresetDisplayName, forKey: eqDefaultsKeyPreset)
        let doubles = equaliserBandDecibels.map(Double.init)
        if let data = try? JSONEncoder().encode(doubles) {
            defaults.set(data, forKey: eqDefaultsKeyBands)
        }
    }

    private func loadEqualiserStateFromUserDefaults() {
        isRestoringEqualiserState = true
        defer {
            isRestoringEqualiserState = false
            pushEqualiserToAudioUnit()
        }
        let defaults = UserDefaults.standard
        equaliserEnabled = defaults.bool(forKey: eqDefaultsKeyEnabled)
        if let pre = defaults.object(forKey: eqDefaultsKeyPreamp) as? Float {
            equaliserPreampDecibels = GraphicEqualiserConfiguration.clampedDecibel(pre)
        } else if let pre = defaults.object(forKey: eqDefaultsKeyPreamp) as? Double {
            equaliserPreampDecibels = GraphicEqualiserConfiguration.clampedDecibel(Float(pre))
        }
        if let data = defaults.data(forKey: eqDefaultsKeyBands),
           let decoded = try? JSONDecoder().decode([Double].self, from: data),
           decoded.count == GraphicEqualiserConfiguration.bandCount {
            equaliserBandDecibels = decoded.map { GraphicEqualiserConfiguration.clampedDecibel(Float($0)) }
        }
        if let name = defaults.string(forKey: eqDefaultsKeyPreset) {
            equaliserPresetDisplayName = name
        }
    }

    // MARK: - Session

    /// Configures and activates the shared session on the main actor. Mutating `AVAudioSession` from a
    /// background queue is unsupported; some OS builds also return `paramErr` (OSStatus **-50**) for
    /// invalid **category + mode + options** combinations — e.g. `.allowBluetoothA2DP` / `.allowAirPlay`
    /// with a mode the system rejects — which surfaces as `SessionCore` “Failed to set properties”.
    private func preparePlaybackSessionIfNeeded() async {
        if playbackSessionPrepared { return }
        if let sessionActivationTask {
            await sessionActivationTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.activateSharedAudioSessionForPlayback() {
                self.playbackSessionPrepared = true
            }
        }
        sessionActivationTask = task
        await task.value
        sessionActivationTask = nil
    }

    /// Returns whether the shared session was configured and activated.
    private func activateSharedAudioSessionForPlayback() -> Bool {
        let session = AVAudioSession.sharedInstance()

        struct Attempt {
            let mode: AVAudioSession.Mode
            let options: AVAudioSession.CategoryOptions
        }
        // Prefer minimal options first; add routing flags only if needed.
        let attempts: [Attempt] = [
            Attempt(mode: .default, options: []),
            Attempt(mode: .moviePlayback, options: []),
            Attempt(mode: .default, options: [.allowBluetoothA2DP]),
            Attempt(mode: .moviePlayback, options: [.allowBluetoothA2DP]),
            Attempt(mode: .default, options: [.allowAirPlay]),
            Attempt(mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay]),
            Attempt(mode: .moviePlayback, options: [.allowBluetoothA2DP, .allowAirPlay]),
        ]

        for pass in 0 ..< 2 {
            if pass == 1 {
                // Second pass: reset session when the first pass failed entirely (e.g. stale activation).
                try? session.setActive(false)
            }
            for attempt in attempts {
                do {
                    try session.setCategory(.playback, mode: attempt.mode, options: attempt.options)
                    try session.setActive(true)
                    #if DEBUG
                    NSLog(
                        "UXMusic: AVAudioSession OK pass=%d mode=%@ options=0x%x",
                        pass,
                        attempt.mode.rawValue,
                        attempt.options.rawValue
                    )
                    #endif
                    return true
                } catch {
                    #if DEBUG
                    NSLog(
                        "UXMusic: AVAudioSession attempt failed pass=%d mode=%@ options=0x%x error=%@",
                        pass,
                        attempt.mode.rawValue,
                        attempt.options.rawValue,
                        String(describing: error)
                    )
                    #endif
                }
            }
            do {
                try session.setCategory(.playback, options: [])
                try session.setActive(true)
                #if DEBUG
                NSLog("UXMusic: AVAudioSession OK pass=%d via setCategory(.playback, options: [])", pass)
                #endif
                return true
            } catch {
                #if DEBUG
                NSLog("UXMusic: AVAudioSession fallback failed pass=%d: %@", pass, String(describing: error))
                #endif
            }
        }
        return false
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickPlaybackPosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func tickPlaybackPosition() {
        guard currentSong != nil else { return }
        if let file = currentAudioFile {
            let sr = file.processingFormat.sampleRate
            if sr > 0, durationSeconds <= 0 {
                durationSeconds = Double(file.length) / sr
            }
        }
        let nextPos = currentTimelineSeconds()
        if durationSeconds > 0 {
            positionSeconds = min(max(0, nextPos), durationSeconds)
        } else {
            positionSeconds = max(0, nextPos)
        }
        syncIsPlayingFromNode()
        updateNowPlayingCentre()
    }

    private func currentTimelineSeconds() -> Double {
        if let frozen = frozenPositionWhilePaused {
            return frozen
        }
        guard let file = currentAudioFile else { return positionSeconds }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return positionSeconds }
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return Double(scheduledSegmentStartFrame) / sr
        }
        return (Double(scheduledSegmentStartFrame) + Double(playerTime.sampleTime)) / sr
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
                self.frozenPositionWhilePaused = self.currentTimelineSeconds()
                self.playerNode.pause()
            } else if self.currentAudioFile != nil {
                self.frozenPositionWhilePaused = nil
                self.ensureEngineRunning()
                self.playerNode.play()
            } else if let song = self.currentSong {
                await self.loadAndPlay(song)
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

    /// Jumps to a track already present in the queue and starts playback.
    func playQueueItem(at index: Int) async {
        guard index >= 0, index < queue.count else { return }
        currentIndex = index
        let s = queue[currentIndex]
        currentSong = s
        await loadAndPlay(s)
    }

    func seek(to seconds: Double) async {
        guard let file = currentAudioFile else { return }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return }
        let length = file.length
        let frame = AVAudioFramePosition(seconds * sr)
        let start = min(max(0, frame), max(length - 1, 0))
        let remaining = AVAudioFrameCount(max(0, length - start))

        let wasPlaying = playerNode.isPlaying
        playerNode.stop()
        frozenPositionWhilePaused = nil
        scheduledSegmentStartFrame = start
        positionSeconds = Double(start) / sr

        let completion: AVAudioNodeCompletionHandler = { [weak self] in
            Task { @MainActor in
                await self?.advanceAfterEnd()
            }
        }

        if remaining > 0 {
            playerNode.scheduleSegment(file, startingFrame: start, frameCount: remaining, at: nil, completionHandler: completion)
        }
        if wasPlaying {
            ensureEngineRunning()
            playerNode.play()
        } else {
            frozenPositionWhilePaused = Double(start) / sr
        }
        syncIsPlayingFromNode()
        updateNowPlayingCentre()
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        currentAudioFile = nil
        currentSong = nil
        currentIndex = -1
        queue = []
        isPlaying = false
        positionSeconds = 0
        durationSeconds = 0
        scheduledSegmentStartFrame = 0
        frozenPositionWhilePaused = nil
        lastWireFormat = nil
        lastPublishedNowPlayingSongId = nil
        artworkLoadedForSongId = nil
        artworkInFlightForSongId = nil
        nowPlayingArtworkImage = nil
        updateNowPlayingCentre()
    }

    private func loadAndPlay(_ song: Song) async {
        await preparePlaybackSessionIfNeeded()
        await Task.yield()

        let path = song.path
        guard FileManager.default.fileExists(atPath: path) else {
            #if DEBUG
            NSLog("UXMusic: missing local file at %@", path)
            #endif
            return
        }

        let url = URL(fileURLWithPath: path)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            #if DEBUG
            NSLog("UXMusic: AVAudioFile open failed: %@ — %@", path, String(describing: error))
            #endif
            return
        }

        do {
            try prepareGraph(for: file)
        } catch {
            #if DEBUG
            NSLog("UXMusic: prepareGraph failed: %@", String(describing: error))
            #endif
            return
        }

        currentAudioFile = file
        let sr = file.processingFormat.sampleRate
        durationSeconds = sr > 0 ? Double(file.length) / sr : 0

        playerNode.stop()
        scheduledSegmentStartFrame = 0
        frozenPositionWhilePaused = nil
        positionSeconds = 0

        let completion: AVAudioNodeCompletionHandler = { [weak self] in
            Task { @MainActor in
                await self?.advanceAfterEnd()
            }
        }

        playerNode.scheduleFile(file, at: nil, completionHandler: completion)

        applyLoudnessGain()
        pushEqualiserToAudioUnit()

        do {
            try ensureEngineRunningThrowing()
            playerNode.play()
        } catch {
            #if DEBUG
            NSLog("UXMusic: engine start / play failed: %@", String(describing: error))
            #endif
        }

        syncIsPlayingFromNode()
        updateNowPlayingCentre()
    }

    private func prepareGraph(for file: AVAudioFile) throws {
        let fmt = file.processingFormat
        if !nodesAttached {
            engine.attach(playerNode)
            engine.attach(equaliserUnit)
            nodesAttached = true
        }

        let sameFormat = lastWireFormat?.sampleRate == fmt.sampleRate && lastWireFormat?.channelCount == fmt.channelCount
        if sameFormat { return }

        if engine.isRunning {
            engine.stop()
        }
        playerNode.stop()

        if lastWireFormat != nil {
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(equaliserUnit)
        }

        engine.connect(playerNode, to: equaliserUnit, format: fmt)
        engine.connect(equaliserUnit, to: engine.mainMixerNode, format: fmt)
        lastWireFormat = fmt
        engine.prepare()
    }

    private func ensureEngineRunning() {
        do {
            try ensureEngineRunningThrowing()
        } catch {
            #if DEBUG
            NSLog("UXMusic: engine.start error: %@", String(describing: error))
            #endif
        }
    }

    private func ensureEngineRunningThrowing() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    private func syncIsPlayingFromNode() {
        let next = playerNode.isPlaying
        guard next != isPlaying else { return }
        isPlaying = next
    }

    private func advanceAfterEnd() async {
        guard queue.count > 1 else { return }
        await next()
    }

    private func applyLoudnessGain() {
        let linear: Float
        if !normaliseEnabled || currentSong == nil {
            linear = 1
        } else if let id = currentSong?.id, let lufs = loudnessMap[id] {
            let gainDb = targetLoudness - lufs
            let lin = pow(10, gainDb / 20)
            linear = min(max(Float(lin), 0), 4)
        } else {
            linear = 1
        }
        engine.mainMixerNode.outputVolume = masterVolume * linear
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
                self.frozenPositionWhilePaused = nil
                self.ensureEngineRunning()
                self.playerNode.play()
                self.syncIsPlayingFromNode()
                self.updateNowPlayingCentre()
            }
            return .success
        }

        c.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                self.frozenPositionWhilePaused = self.currentTimelineSeconds()
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
                    self.frozenPositionWhilePaused = self.currentTimelineSeconds()
                    self.playerNode.pause()
                    self.syncIsPlayingFromNode()
                case .ended:
                    if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                        let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                        if opts.contains(.shouldResume) {
                            try? AVAudioSession.sharedInstance().setActive(true)
                            self.frozenPositionWhilePaused = nil
                            self.ensureEngineRunning()
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
