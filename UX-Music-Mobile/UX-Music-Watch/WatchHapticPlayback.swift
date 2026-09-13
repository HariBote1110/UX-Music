import AVFoundation
import Combine
import Foundation
import WatchKit

private let watchHapticLatencyQueue = DispatchQueue(
    label: "UXMusicWatch.hapticPlayback.latency",
    qos: .utility
)
private let watchHapticsEnabledUserDefaultsKey = "watchHapticsEnabled"

/// Queue-confined scheduler for the production haptic stream. Its timer never performs main-actor
/// work other than the single WatchKit `play` call for a fired onset.
private final class WatchHapticPlaybackRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "UXMusicWatch.hapticPlayback.timer",
        qos: .userInteractive
    )
    private var timer: DispatchSourceTimer?
    private var snapshot: WatchHapticPlaybackClockSnapshot?
    private var onsets: [WatchHapticOnset] = []
    private var onsetIndex = 0
    private var outputLatency: TimeInterval = 0
    private var songId = "-"
    private var active = false
    private var nextReportUptime: TimeInterval = 0
    private var fired = 0
    private var skippedLate = 0
    private var filtered = 0
    private var runtimeGapFiltered = 0
    private var lateSamples: [TimeInterval] = []
    private var lastFiredUptime: TimeInterval?
    private var lastFiredMediaTime: Double?
    private var generation: UInt = 0

    func update(
        snapshot: WatchHapticPlaybackClockSnapshot,
        onsets: [WatchHapticOnset],
        filteredCount: Int,
        outputLatency: TimeInterval
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Self.uptime
            let previousSnapshot = self.snapshot
            let startsNewStream = !self.active || self.songId != (snapshot.songId ?? "-")
            if startsNewStream {
                self.resetStatistics(songId: snapshot.songId ?? "-", now: now)
            }
            let isDiscontinuity = startsNewStream || WatchHapticPlaybackPlanner.isDiscontinuity(
                previous: previousSnapshot,
                next: snapshot
            )
            self.active = true
            self.snapshot = snapshot
            self.onsets = onsets
            self.filtered = filteredCount
            self.outputLatency = max(0, outputLatency)
            self.reanchor(now: now, resetIndex: isDiscontinuity)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            self.cancelTimer()
            self.active = false
            self.snapshot = nil
            self.onsets.removeAll()
            self.onsetIndex = 0
            self.lastFiredMediaTime = nil
        }
    }

    private func resetStatistics(songId: String, now: TimeInterval) {
        cancelTimer()
        self.songId = songId
        fired = 0
        skippedLate = 0
        filtered = 0
        runtimeGapFiltered = 0
        lateSamples.removeAll(keepingCapacity: true)
        lastFiredUptime = nil
        lastFiredMediaTime = nil
        nextReportUptime = now + 10
    }

    private func reanchor(now: TimeInterval, resetIndex: Bool) {
        generation &+= 1
        cancelTimer()
        guard active, let snapshot else { return }

        if resetIndex,
           let audibleMediaTime = WatchHapticPlaybackPlanner.audibleMediaTime(
               snapshot: snapshot,
               now: now,
               outputLatency: outputLatency
           ) {
            let mediaTimes = onsets.map(\.time)
            onsetIndex = WatchHapticPlaybackPlanner.resumeIndex(
                onsetTimes: mediaTimes,
                audibleMediaTime: audibleMediaTime,
                lastFiredMediaTime: lastFiredMediaTime
            )
            skipOnsetsThatAreAlreadyLate(now: now, snapshot: snapshot)
        }

        let nextFire = nextFireUptime(snapshot: snapshot)
        scheduleTimer(for: nextFire.map { min($0, nextReportUptime) } ?? nextReportUptime)
    }

    private func skipOnsetsThatAreAlreadyLate(
        now: TimeInterval,
        snapshot: WatchHapticPlaybackClockSnapshot
    ) {
        while onsetIndex < onsets.count,
              let fireUptime = WatchHapticPlaybackPlanner.fireUptime(
                  forMediaTime: onsets[onsetIndex].time,
                  snapshot: snapshot,
                  outputLatency: outputLatency
              ),
              WatchHapticPlaybackPlanner.shouldSkipLate(fireUptime: fireUptime, now: now) {
            skippedLate += 1
            onsetIndex += 1
        }
    }

    private func nextFireUptime(snapshot: WatchHapticPlaybackClockSnapshot) -> TimeInterval? {
        guard onsetIndex < onsets.count else { return nil }
        return WatchHapticPlaybackPlanner.fireUptime(
            forMediaTime: onsets[onsetIndex].time,
            snapshot: snapshot,
            outputLatency: outputLatency
        )
    }

    private func scheduleTimer(for uptime: TimeInterval) {
        let generation = self.generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.timerFired(generation: generation)
        }
        self.timer = timer
        timer.schedule(
            deadline: DispatchTime(uptimeNanoseconds: UInt64(max(0, uptime) * 1_000_000_000)),
            leeway: .nanoseconds(0)
        )
        // Dispatch sources start suspended. Resuming is required before the first tick.
        timer.resume()
    }

    private func timerFired(generation: UInt) {
        guard active, generation == self.generation, let snapshot else { return }
        let now = Self.uptime

        if now >= nextReportUptime {
            report()
            repeat {
                nextReportUptime += 10
            } while nextReportUptime <= now
        }

        guard onsetIndex < onsets.count else {
            cancelTimer()
            scheduleTimer(for: nextReportUptime)
            return
        }

        guard let fireUptime = nextFireUptime(snapshot: snapshot) else {
            onsetIndex += 1
            reanchor(now: now, resetIndex: false)
            return
        }

        guard now >= fireUptime else {
            cancelTimer()
            scheduleTimer(for: min(fireUptime, nextReportUptime))
            return
        }

        if WatchHapticPlaybackPlanner.shouldSkipLate(fireUptime: fireUptime, now: now) {
            skippedLate += 1
            onsetIndex += 1
            reanchor(now: now, resetIndex: false)
            return
        }

        if let lastFiredUptime,
           fireUptime - lastFiredUptime < WatchHapticPlaybackPlanner.defaultMinimumGap {
            runtimeGapFiltered += 1
            onsetIndex += 1
            reanchor(now: now, resetIndex: false)
            return
        }

        fired += 1
        lateSamples.append(max(0, now - fireUptime))
        lastFiredUptime = now
        lastFiredMediaTime = onsets[onsetIndex].time
        onsetIndex += 1
        DispatchQueue.main.async {
            WKInterfaceDevice.current().play(.failure)
        }
        reanchor(now: now, resetIndex: false)
    }

    private func report() {
        #if DEBUG
        let sorted = lateSamples.sorted()
        let p95: TimeInterval
        if let last = sorted.indices.last {
            let index = min(last, Int(Double(last) * 0.95))
            p95 = sorted[index]
        } else {
            p95 = 0
        }
        print(String(
            format: "[HapticPlayback] song=%@ fired=%d skippedLate=%d filtered=%d latencyMs=%.1f lateP95=%.1f",
            songId,
            fired,
            skippedLate,
            filtered + runtimeGapFiltered,
            outputLatency * 1_000,
            p95 * 1_000
        ))
        #endif
    }

    private func cancelTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private static var uptime: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

@MainActor
final class WatchHapticPlayback: NSObject, ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var currentSongHasMap = false

    private let player: WatchAudioPlayerService
    private let library: WatchLocalLibrary
    private let preferencesQueue = DispatchQueue(
        label: "UXMusicWatch.hapticPlayback.preferences",
        qos: .utility
    )
    private let runtime = WatchHapticPlaybackRuntime()
    private var cancellables = Set<AnyCancellable>()
    private var mapLoadTask: Task<Void, Never>?
    private var currentSongID: String?
    private var currentMap: WatchHapticMap?
    private var sceneIsActive = false
    private var outputLatency: TimeInterval = 0

    init(player: WatchAudioPlayerService, library: WatchLocalLibrary) {
        self.player = player
        self.library = library
        self.isEnabled = false
        super.init()

        player.$currentSong
            .sink { [weak self] song in
                self?.currentSongDidChange(song)
            }
            .store(in: &cancellables)
        player.$isPlaying
            .sink { [weak self] _ in
                self?.refreshScheduling()
            }
            .store(in: &cancellables)
        player.playbackClock.$snapshot
            .sink { [weak self] _ in
                self?.refreshScheduling()
            }
            .store(in: &cancellables)

        preferencesQueue.async { [weak self] in
            let enabled = UserDefaults.standard.object(forKey: watchHapticsEnabledUserDefaultsKey) as? Bool ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isEnabled = enabled
                self.refreshScheduling()
            }
        }

        watchHapticLatencyQueue.async { [weak self] in
            self?.readOutputLatency()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSessionRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        preferencesQueue.async {
            UserDefaults.standard.set(enabled, forKey: watchHapticsEnabledUserDefaultsKey)
        }
        refreshScheduling()
    }

    /// Called by the root view's scene-phase hook; haptics intentionally stop when the app is not
    /// active because watchOS does not continue this haptic stream with the screen off.
    func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        refreshScheduling()
    }

    /// Reloads only when a newly received map belongs to the currently loaded song.
    func reloadMapIfCurrentSong(id: String) {
        guard currentSongID == id else { return }
        loadMap(for: id)
    }

    private func currentSongDidChange(_ song: WatchTransferMeta?) {
        guard currentSongID != song?.id else { return }
        currentSongID = song?.id
        currentMap = nil
        currentSongHasMap = false
        mapLoadTask?.cancel()
        runtime.stop()
        guard let id = song?.id else { return }
        loadMap(for: id)
    }

    private func loadMap(for songID: String) {
        mapLoadTask?.cancel()
        currentMap = nil
        currentSongHasMap = false
        runtime.stop()
        mapLoadTask = Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) {
                let url = WatchAudioStorage.hapticsFileURL(forId: songID)
                guard let data = try? Data(contentsOf: url) else { return nil as WatchHapticMap? }
                return try? JSONDecoder().decode(WatchHapticMap.self, from: data)
            }.value
            guard !Task.isCancelled, let self, self.currentSongID == songID,
                  decoded?.songId == songID else { return }
            self.currentMap = decoded
            self.currentSongHasMap = true
            self.refreshScheduling()
        }
    }

    private func refreshScheduling() {
        guard isEnabled,
              sceneIsActive,
              player.isPlaying,
              let currentSongID,
              let currentMap,
              let snapshot = player.playbackClock.snapshot,
              snapshot.songId == currentSongID
        else {
            runtime.stop()
            return
        }

        let onsets = WatchHapticPlaybackPlanner.filteredOnsets(
            onsetTimes: currentMap.onsetTimes,
            strengths: currentMap.strengths
        )
        runtime.update(
            snapshot: snapshot,
            onsets: onsets,
            filteredCount: max(0, currentMap.onsetTimes.count - onsets.count),
            outputLatency: outputLatency
        )
    }

    @objc private nonisolated func audioSessionRouteChange(_ notification: Notification) {
        watchHapticLatencyQueue.async { [weak self] in
            self?.readOutputLatency()
        }
    }

    private nonisolated func readOutputLatency() {
        let latency = max(0, AVAudioSession.sharedInstance().outputLatency)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.outputLatency = latency
            self.refreshScheduling()
        }
    }
}
