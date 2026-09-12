import AVFoundation
import Foundation
import MediaPlayer

/// Playback progress, split out from `WatchAudioPlayerService` into its own `ObservableObject` so
/// that the 0.5s-interval position tick does not fire `WatchAudioPlayerService.objectWillChange`.
/// SwiftUI re-renders *every* view holding an `@EnvironmentObject` reference to an object whenever
/// any of its `@Published` properties change, regardless of whether that view actually reads the
/// changed property — with `position` living on the same object as `currentSong`/`isPlaying`, the
/// Library page (which never reads `position`) was being torn down and rebuilt twice a second,
/// which is what produced the audible stutter when swiping between Library and Now Playing. Only
/// `WatchNowPlayingView` injects this object, so Library never observes it.
@MainActor
final class WatchPlaybackProgress: ObservableObject {
    @Published var position: Double = 0
}

/// AVPlayer-backed playback service for the Watch app, using the platform's actual route for
/// standalone background music playback: `AVAudioSession`'s `.playback` category with either the
/// `.longFormAudio` route-sharing policy or the plain `.default` policy, activated via
/// `AVAudioSession.activate(options:completionHandler:)`.
/// This is the correct mechanism for watchOS background audio — `WKExtendedRuntimeSession` (used
/// previously) is intended for workouts and similar long-running *foreground-eligible* tasks, not
/// music playback, and does not reliably keep `AVPlayer` audio going once the screen locks.
///
/// **Hardware constraint**: watchOS does not allow *long-form* audio playback over the built-in
/// speaker. The output preference therefore controls whether `.longFormAudio` is attempted at
/// all; plain `.playback`/`.default` is used for deliberate speaker playback and automatic mode
/// when no Bluetooth route is detected.
///
/// System integration: publishes state to `MPNowPlayingInfoCenter` and wires
/// `MPRemoteCommandCenter` (play/pause/next/previous) so the standard watchOS "Now Playing" glance,
/// AirPods controls, and the paired iPhone's control centre all reflect and drive this player.
@MainActor
final class WatchAudioPlayerService: NSObject, ObservableObject {

    @Published var currentSong: WatchTransferMeta?
    @Published var isPlaying = false
    @Published var repeatMode: WatchRepeatMode = .off
    @Published var isShuffled = false
    /// The persisted user preference for selecting the Watch speaker or a Bluetooth route.
    @Published private(set) var outputPreference: WatchAudioOutputPreference
    /// Set only when all selected activation attempts fail (see `activateAudioSession`) — no audio
    /// output is available at all. `WatchNowPlayingView` surfaces this as a blocking message;
    /// cleared on the next successful activation.
    @Published var routeError: String?
    /// `true` whenever the current session is the plain speaker session, whether the user selected
    /// the speaker explicitly or it was reached as an automatic fallback.
    /// `WatchNowPlayingView` surfaces this as a small non-blocking caption rather than `routeError`.
    @Published var isSpeakerFallback = false
    /// DEBUG-only on-screen diagnostic surfaced by `WatchNowPlayingView` — a short human-readable
    /// summary of the last `applyRouteOutcome` call (outcome + first output port name), e.g.
    /// "longForm / AirPods Pro" or "fallback / Speaker". Added because real-device background
    /// audio failures cannot be observed via the console (no cable while off the wrist), so the
    /// last-known route needs to be visible on the watch face itself.
    #if DEBUG
    @Published var sessionDiagnostic: String?
    #endif

    /// Playback position, split into `progress` (see above) to avoid the Library page re-rendering
    /// on every tick. Kept as a computed passthrough so the rest of this type (seek clamping,
    /// "restart vs skip back" threshold, Now Playing info) can keep reading `position` as before.
    var position: Double {
        get { progress.position }
        set { progress.position = newValue }
    }
    let progress = WatchPlaybackProgress()

    /// Read-only view of the queue as it is actually playing (post-shuffle, if shuffled), for
    /// `WatchQueueView`'s "up next" list. A plain computed passthrough (rather than a second
    /// `@Published` copy) — `queue` only ever changes together with `currentSong`/`isPlaying`, both
    /// of which already drive a re-render of any view observing this object, so there is nothing to
    /// duplicate or keep in sync.
    var playbackQueue: [WatchTransferMeta] { queue }

    private var player: AVPlayer?
    /// The queue as it is actually playing (shuffled, if `isShuffled`).
    private var queue: [WatchTransferMeta] = []
    /// The queue in its original (un-shuffled) order, so toggling shuffle off can restore it.
    private var originalQueue: [WatchTransferMeta] = []
    private var currentIndex = 0
    private var timeObserver: Any?
    private let library: WatchLocalLibrary
    /// The policy last successfully activated, or `nil` if activation has never succeeded (or has
    /// since failed). Feeds `WatchAudioActivationPolicy.plan` so `activateAudioSession` can skip
    /// redundant `setCategory`/`activate` calls only when the policy still matches the preference.
    private var activatedPolicy: WatchAudioActivationPolicy.ActivatedPolicy?

    init(library: WatchLocalLibrary) {
        self.library = library
        outputPreference = UserDefaults.standard.string(
            forKey: WatchAudioOutputPreference.userDefaultsKey
        ).flatMap(WatchAudioOutputPreference.init(rawValue:)) ?? .automatic
        super.init()
        configureRemoteCommands()
        configureAudioSessionNotifications()
    }

    /// Persists the requested output and, when an audio session is active, re-activates it under
    /// the new plan without losing whether playback was running.
    func setOutputPreference(_ preference: WatchAudioOutputPreference) {
        guard preference != outputPreference else { return }
        outputPreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: WatchAudioOutputPreference.userDefaultsKey)

        guard activatedPolicy != nil else { return }

        let wasPlaying = isPlaying
        if wasPlaying {
            player?.pause()
            isPlaying = false
            updateNowPlayingInfo()
            saveResumeState()
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [])
        } catch {
            print("[WatchAudioPlayer] setActive(false) error while changing output preference: \(error)")
        }
        activatedPolicy = nil
        routeError = nil
        isSpeakerFallback = false

        activateAudioSession { [weak self] activated in
            guard let self, wasPlaying, activated else { return }
            self.player?.play()
            self.isPlaying = true
            self.updateNowPlayingInfo()
            self.saveResumeState()
        }
    }

    /// Starts playing `song` from `queue`. Activates the `AVAudioSession` according to the user's
    /// output preference and only starts the `AVPlayer` once activation succeeds.
    func play(_ song: WatchTransferMeta, queue songs: [WatchTransferMeta]) {
        originalQueue = songs
        if isShuffled {
            queue = WatchShuffleLogic.applyShuffle(
                queue: songs,
                shuffledIndices: Array(songs.indices).shuffled(),
                currentId: song.id
            )
        } else {
            queue = songs
        }
        currentIndex = queue.firstIndex(where: { $0.id == song.id }) ?? 0
        let target = queue[currentIndex]
        activateAudioSession { [weak self] activated in
            guard let self, activated else { return }
            self.load(target)
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            updateNowPlayingInfo()
            saveResumeState()
        } else {
            activateAudioSession { [weak self] activated in
                guard let self, activated else { return }
                player.play()
                self.isPlaying = true
                self.updateNowPlayingInfo()
                self.saveResumeState()
            }
        }
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

    /// Cycles repeat mode off → all → one → off, mirroring a physical Walkman's repeat button.
    func cycleRepeatMode() {
        repeatMode = repeatMode.next()
        saveResumeState()
    }

    /// Toggles shuffle. Turning it on reshuffles the current queue, keeping the currently-playing
    /// song first so playback is not interrupted; turning it off restores the original queue order.
    func toggleShuffle() {
        isShuffled.toggle()
        let currentId = currentSong?.id
        if isShuffled {
            queue = WatchShuffleLogic.applyShuffle(
                queue: originalQueue,
                shuffledIndices: Array(originalQueue.indices).shuffled(),
                currentId: currentId
            )
        } else {
            queue = originalQueue
        }
        if let currentId {
            currentIndex = WatchResumeLogic.resumeIndex(songId: currentId, queue: queue) ?? currentIndex
        }
        saveResumeState()
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
        saveResumeState()
    }

    /// Restores the last-played song, queue, position, and mode from disk (see
    /// `WatchPlaybackResumeState`). Loads the track and seeks to the saved position but does
    /// **not** start playback — a cold app launch should not surprise the user with audio.
    func restoreResumeState() {
        guard let state = WatchResumeStorage.load() else { return }
        repeatMode = state.repeatMode
        isShuffled = state.isShuffled

        let resolvedQueue = WatchResumeLogic.resolveSongs(ids: state.queueSongIds, librarySongs: library.songs)
        let resolvedOriginal = WatchResumeLogic.resolveSongs(ids: state.originalQueueSongIds, librarySongs: library.songs)
        guard !resolvedQueue.isEmpty, let index = WatchResumeLogic.resumeIndex(songId: state.songId, queue: resolvedQueue) else { return }

        queue = resolvedQueue
        originalQueue = resolvedOriginal.isEmpty ? resolvedQueue : resolvedOriginal
        currentIndex = index

        loadWithoutAutoplay(queue[currentIndex])
        seek(to: state.position)
    }

    private func load(_ song: WatchTransferMeta) {
        loadWithoutAutoplay(song)
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
        saveResumeState()
    }

    /// Loads `song` into a fresh `AVPlayer` without starting playback — shared by `load(_:)` (which
    /// plays immediately) and `restoreResumeState()` (which must not autoplay on launch).
    private func loadWithoutAutoplay(_ song: WatchTransferMeta) {
        clearPlayer()
        currentSong = song

        let url = library.audioFileURL(for: song)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[WatchAudioPlayer] File not found: \(url.path)")
            return
        }

        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        isPlaying = false
        player = avPlayer

        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // Only touches `progress.position`, not any `@Published` property on `self` — see the
            // doc comment on `WatchPlaybackProgress` for why that split matters.
            self?.progress.position = time.seconds
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        updateNowPlayingInfo()
    }

    /// Activates the ordered attempts selected by the output preference. A speaker attempt never
    /// supplies a route-sharing policy, so it cannot show the long-form route picker.
    private func activateAudioSession(completion: @escaping (Bool) -> Void) {
        let bluetoothDetected = bluetoothOutputDetected()
        let plan = WatchAudioActivationPolicy.plan(
            previouslyActivated: activatedPolicy,
            preference: outputPreference,
            bluetoothDetected: bluetoothDetected
        )
        print("[WatchAudioPlayer] activateAudioSession: previouslyActivated=\(String(describing: activatedPolicy)) preference=\(outputPreference) plan=\(plan)")
        guard plan != .skip else {
            completion(true)
            return
        }

        activateNext(
            attempts: WatchAudioRoutePolicy.attempts(
                preference: outputPreference,
                bluetoothDetected: bluetoothDetected
            ),
            index: 0,
            completion: completion
        )
    }

    private func activateNext(
        attempts: [WatchAudioRoutePolicy.Attempt],
        index: Int,
        completion: @escaping (Bool) -> Void
    ) {
        guard index < attempts.count else {
            activatedPolicy = nil
            applyRouteOutcome(.unavailable)
            completion(false)
            return
        }

        let attempt = attempts[index]
        switch attempt {
        case .longForm:
            activate(category: .playback, mode: .default, policy: .longFormAudio) { [weak self] activated in
                guard let self else { return }
                if activated {
                    self.activatedPolicy = .longForm
                    self.applyRouteOutcome(.longForm)
                    completion(true)
                } else {
                    self.activateNext(attempts: attempts, index: index + 1, completion: completion)
                }
            }
        case .speaker:
            activate(category: .playback, mode: .default, policy: nil) { [weak self] activated in
                guard let self else { return }
                if activated {
                    self.activatedPolicy = .fallback
                    self.applyRouteOutcome(.speakerFallback)
                    completion(true)
                } else {
                    self.activateNext(attempts: attempts, index: index + 1, completion: completion)
                }
            }
        }
    }

    /// Uses the current route and, when watchOS exposes it, available inputs as a small heuristic
    /// for deciding whether automatic mode may try `.longFormAudio`. This heuristic is intentionally
    /// isolated because its behaviour on real watchOS hardware is not yet verified.
    private func bluetoothOutputDetected() -> Bool {
        let session = AVAudioSession.sharedInstance()
        let bluetoothPorts: [AVAudioSession.Port] = [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        let outputs = session.currentRoute.outputs
        let availableInputs = session.availableInputs ?? []
        let detected = outputs.contains { bluetoothPorts.contains($0.portType) }
            || availableInputs.contains { bluetoothPorts.contains($0.portType) }
        let outputTypes = outputs.map(\.portType.rawValue)
        print("[WatchAudioPlayer] bluetoothDetection: outputs=\(outputTypes) detected=\(detected)")
        return detected
    }

    /// Sets category/mode/(optional) route-sharing policy and activates the session asynchronously,
    /// invoking `completion` back on the main actor with whether activation succeeded. `policy: nil`
    /// omits the route-sharing policy argument entirely (letting `AVAudioSession` use its own
    /// `.default`), used for every plain speaker attempt in `activateAudioSession`.
    private func activate(
        category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        policy: AVAudioSession.RouteSharingPolicy?,
        completion: @escaping (Bool) -> Void
    ) {
        let policyDescription = policy.map(String.init(describing:)) ?? "default (no route-sharing policy)"
        print("[WatchAudioPlayer] activate: attempting category=\(category.rawValue) mode=\(mode.rawValue) policy=\(policyDescription)")
        let session = AVAudioSession.sharedInstance()
        do {
            if let policy {
                try session.setCategory(category, mode: mode, policy: policy)
            } else {
                try session.setCategory(category, mode: mode)
            }
        } catch {
            print("[WatchAudioPlayer] AVAudioSession setCategory error for policy=\(policyDescription): \(error)")
            completion(false)
            return
        }
        session.activate(options: []) { activated, error in
            Task { @MainActor in
                print("[WatchAudioPlayer] activate result: policy=\(policyDescription) activated=\(activated) error=\(error.map(String.init(describing:)) ?? "no error")")
                completion(activated)
            }
        }
    }

    /// Applies a `WatchAudioRoutePolicy.Outcome` to `routeError`/`isSpeakerFallback` — the one place
    /// both `@Published` properties are updated together, so they can never disagree (e.g.
    /// `routeError` set while `isSpeakerFallback` is also `true`).
    private func applyRouteOutcome(_ outcome: WatchAudioRoutePolicy.Outcome) {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let routeDescription = outputs.isEmpty
            ? "no outputs"
            : outputs.map { "\($0.portType.rawValue)/\($0.portName)" }.joined(separator: ", ")
        print("[WatchAudioPlayer] applyRouteOutcome: outcome=\(outcome) route=[\(routeDescription)]")

        switch outcome {
        case .longForm:
            routeError = nil
            isSpeakerFallback = false
        case .speakerFallback:
            routeError = nil
            isSpeakerFallback = true
        case .unavailable:
            routeError = String(localized: "Could not start playback on Apple Watch.")
            isSpeakerFallback = false
        }

        #if DEBUG
        let firstPortName = outputs.first?.portName ?? "no output"
        sessionDiagnostic = "\(outcome) / \(firstPortName)"
        #endif
    }

    private func configureAudioSessionNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(
            self,
            selector: #selector(audioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(audioSessionRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
    }

    @objc private func audioSessionInterruption(_ notification: Notification) {
        let userInfo = notification.userInfo
        let type = (userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        let reason = (userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.uintValue
        let options = (userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
        print("[WatchAudioPlayer] interruptionNotification: type=\(String(describing: type)) reason=\(String(describing: reason)) options=\(String(describing: options)) outputs=\(outputs)")

        guard type == AVAudioSession.InterruptionType.began.rawValue,
              isPlaying,
              let player,
              player.rate == 0 else { return }
        isPlaying = false
        updateNowPlayingInfo()
        saveResumeState()
    }

    @objc private func audioSessionRouteChange(_ notification: Notification) {
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
        print("[WatchAudioPlayer] routeChangeNotification: reason=\(String(describing: reason)) outputs=\(outputs)")
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
        switch WatchQueueNavigation.autoAdvance(current: currentIndex, count: queue.count, repeatMode: repeatMode) {
        case .index(let index):
            currentIndex = index
            load(queue[currentIndex])
        case .stop:
            player?.pause()
            isPlaying = false
            position = 0
            player?.seek(to: .zero)
            updateNowPlayingInfo()
            saveResumeState()
        }
    }

    /// Publishes the current track/position/rate to `MPNowPlayingInfoCenter` so watchOS's system
    /// "Now Playing" surface (and the paired iPhone) reflect what is actually playing. Called only
    /// on state changes (load/play/pause/seek), not on every position tick — see
    /// `WatchPlaybackProgress` for why the position tick must not trigger this. `AVPlayer`'s
    /// `MPNowPlayingInfoPropertyElapsedPlaybackTime` + `MPNowPlayingInfoPropertyPlaybackRate` pair
    /// is designed for the system to interpolate elapsed time on its own between updates.
    private func updateNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = WatchNowPlayingInfoBuilder.buildInfo(
            for: currentSong,
            isPlaying: isPlaying,
            position: position
        )
    }

    /// Persists the current "where were we" snapshot to disk so it can be restored on next launch
    /// (see `restoreResumeState()`). Cheap (small JSON file) and called from every state-changing
    /// action rather than on a timer, so a killed process never loses more than the last action.
    private func saveResumeState() {
        guard let currentSong else { return }
        let state = WatchPlaybackResumeState(
            songId: currentSong.id,
            position: position,
            queueSongIds: queue.map(\.id),
            originalQueueSongIds: originalQueue.map(\.id),
            currentIndex: currentIndex,
            repeatMode: repeatMode,
            isShuffled: isShuffled
        )
        WatchResumeStorage.save(state)
    }

    /// Wires `MPRemoteCommandCenter` so play/pause/next/previous from AirPods, the watch's system
    /// Now Playing glance, or the paired iPhone drive this player.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil, !self.isPlaying else { return .commandFailed }
            self.togglePlayPause()
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

/// On-disk storage for `WatchPlaybackResumeState`, under Application Support alongside the library
/// index. Kept as a plain enum (no `WatchAudioPlayerService` dependency) so it mirrors the shape of
/// `WatchAudioStorage` in `WatchLocalLibrary.swift`.
enum WatchResumeStorage {
    static var fileURL: URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportDir.appendingPathComponent("playback-resume.json")
    }

    static func save(_ state: WatchPlaybackResumeState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> WatchPlaybackResumeState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WatchPlaybackResumeState.self, from: data)
    }
}
