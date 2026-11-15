import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

enum LoudnessNormalisation {
    static func linearGain(songID: String?, map: [String: Double], target: Double, enabled: Bool) -> Double {
        guard enabled, let songID, let lufs = map[songID], lufs.isFinite, target.isFinite else { return 1 }
        return min(max(pow(10, (target - lufs) / 20), 0), 4)
    }
}

/// Local playback with optional loudness normalisation and a 10-band graphic equaliser (`AVAudioEngine` + `AVAudioUnitEQ`).
@MainActor
@Observable
final class MusicPlayerService {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let equaliserUnit = AVAudioUnitEQ(numberOfBands: GraphicEqualiserConfiguration.bandCount)
    /// A separate gain stage keeps normalisation active when the graphic equaliser is bypassed.
    private let normalisationUnit = AVAudioUnitEQ(numberOfBands: 0)

    private var queue: [Song] = []
    private var currentIndex: Int = -1
    /// The queue's order before shuffle was turned on, so turning it back off is lossless. Empty
    /// when shuffle is off.
    private var originalQueue: [Song] = []

    /// Current playback queue (local files), in play order.
    var playbackQueue: [Song] { queue }
    /// Index of the current track in `playbackQueue`, or `-1` when idle.
    var currentQueueIndex: Int { currentIndex }

    // MARK: - Repeat / shuffle

    private(set) var repeatMode: PlaybackRepeatMode = .off
    /// The queue's current shuffle state. This can temporarily differ from the persisted baseline
    /// while a collection-specific preference is active.
    private(set) var isShuffleEnabled = false
    private var baselineShuffleEnabled = false
    private let repeatModeDefaultsKey = "uxmusic.playback.repeatMode"
    private let shuffleEnabledDefaultsKey = "uxmusic.playback.shuffleEnabled"
    private let collectionShufflePreferenceStore: CollectionShufflePreferenceStore

    /// Cycles repeat off → all → one → off, matching a physical Walkman's repeat button.
    func cycleRepeatMode() {
        setRepeatMode(repeatMode.next())
    }

    func setRepeatMode(_ mode: PlaybackRepeatMode) {
        guard mode != repeatMode else { return }
        repeatMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: repeatModeDefaultsKey)
    }

    func toggleShuffle() {
        setShuffleEnabled(!isShuffleEnabled)
    }

    /// Turning shuffle on reorders `queue` (keeping the currently-playing song at its current
    /// position, not interrupting playback); turning it off restores `originalQueue` and recomputes
    /// `currentIndex` for the currently-playing song.
    func setShuffleEnabled(_ enabled: Bool) {
        baselineShuffleEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: shuffleEnabledDefaultsKey)
        guard enabled != isShuffleEnabled else { return }
        let currentId = currentSong?.id
        // With the same song in the queue more than once, the playing copy is identified by its
        // occurrence rank in the queue being left, then re-found at the same rank in the new order.
        let currentRank = PlaybackQueueEditing.occurrenceRank(ofIndex: currentIndex, in: queue, id: { $0.id })
        if enabled {
            originalQueue = queue
            let indices = Array(queue.indices).shuffled()
            queue = PlaybackShuffleLogic.applyShuffle(queue: queue, shuffledIndices: indices, currentId: currentId)
        } else {
            queue = originalQueue
            originalQueue = []
        }
        if let currentId, let idx = PlaybackQueueEditing.occurrenceIndex(rank: currentRank, ofId: currentId, in: queue, id: { $0.id }) {
            currentIndex = idx
        }
        isShuffleEnabled = enabled
    }

    private func loadPlaybackModesFromUserDefaults() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: repeatModeDefaultsKey), let mode = PlaybackRepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        baselineShuffleEnabled = defaults.bool(forKey: shuffleEnabledDefaultsKey)
        isShuffleEnabled = baselineShuffleEnabled
    }

    // MARK: - Queue editing

    /// Moves the item at `from` so it ends up at index `to` in the resulting queue, keeping
    /// `currentIndex` pointing at the same song (playback is not interrupted — this never loads a
    /// different track). While shuffled this reorders only `queue`; `originalQueue` keeps its order,
    /// so turning shuffle off restores the original order.
    func moveQueueItem(from: Int, to: Int) {
        guard queue.indices.contains(from) else { return }
        let newCurrentIndex = PlaybackQueueEditing.currentIndexAfterMoving(from: from, to: to, currentIndex: currentIndex)
        queue = PlaybackQueueEditing.moveElement(in: queue, from: from, to: to)
        currentIndex = newCurrentIndex
    }

    /// Removes the item at `index`. Removing the currently-playing item advances playback to
    /// whatever takes its place; removing the last remaining item stops playback entirely.
    func removeQueueItem(at index: Int) async {
        guard queue.indices.contains(index) else { return }
        if isShuffleEnabled {
            originalQueue = PlaybackQueueEditing.originalQueueAfterRemoving(
                queue: queue, originalQueue: originalQueue, removedIndex: index, id: { $0.id }
            )
        }
        let wasCurrent = index == currentIndex
        guard let newCurrentIndex = PlaybackQueueEditing.currentIndexAfterRemoving(
            removedIndex: index,
            currentIndex: currentIndex,
            countBefore: queue.count
        ) else {
            stop()
            return
        }
        queue.remove(at: index)
        currentIndex = newCurrentIndex
        if wasCurrent, queue.indices.contains(currentIndex) {
            let generation = playGeneration.bump()
            let s = queue[currentIndex]
            currentSong = s
            await loadActive(s, generation: generation)
        }
    }

    /// Inserts `song` immediately after the currently-playing item ("play next"). When the queue is
    /// empty, becomes the new (unstarted) queue.
    func insertNext(_ song: Song) {
        guard currentIndex >= 0 else {
            queue = [song]
            currentIndex = 0
            if isShuffleEnabled {
                originalQueue = PlaybackQueueEditing.originalQueueAfterAppending(originalQueue: originalQueue, appended: song)
            }
            return
        }
        if isShuffleEnabled {
            originalQueue = PlaybackQueueEditing.originalQueueAfterInsertingNext(
                queue: queue, originalQueue: originalQueue, currentIndex: currentIndex, inserted: song, id: { $0.id }
            )
        }
        queue.insert(song, at: min(currentIndex + 1, queue.count))
    }

    /// Appends `song` to the end of the queue. When the queue is empty, becomes the new
    /// (unstarted) queue.
    func appendToQueue(_ song: Song) {
        guard currentIndex >= 0 else {
            queue = [song]
            currentIndex = 0
            if isShuffleEnabled {
                originalQueue = PlaybackQueueEditing.originalQueueAfterAppending(originalQueue: originalQueue, appended: song)
            }
            return
        }
        if isShuffleEnabled {
            originalQueue = PlaybackQueueEditing.originalQueueAfterAppending(originalQueue: originalQueue, appended: song)
        }
        queue.append(song)
    }

    private var positionTimer: Timer?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    private(set) var currentSong: Song? {
        didSet { applyLoudnessGain() }
    }
    private(set) var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            if isPlaying {
                startPositionTimer()
            } else {
                stopPositionTimer()
                settlePositionAfterPause()
            }
        }
    }
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0

    var loudnessMap: [String: Double] = [:] {
        didSet { applyLoudnessGain() }
    }
    var targetLoudness: Double = AppConstants.defaultTargetLoudness {
        didSet { applyLoudnessGain() }
    }
    var normaliseEnabled = true {
        didSet { applyLoudnessGain() }
    }
    var masterVolume: Float = 1 {
        didSet { applyLoudnessGain() }
    }

    /// Optional hook for platforms that keep audio files in a local cache rather than always
    /// having `song.path` point at something readable (tvOS: only the initially tapped song's
    /// `path` is rewritten to the cache file by `TVPlaybackController`; every other queue entry
    /// still carries its server-side path). When `loadAndPlay` finds `song.path` missing, it
    /// calls this closure and, if it returns a song, retries with that song's `path` instead —
    /// so skip/auto-advance/remote-command paths all resolve through the same place `play(_:)`
    /// already goes through on tvOS. `nil` on iOS/watchOS, where every queue entry's `path` is
    /// already a real local file.
    var localFileResolver: ((Song) async -> Song?)?

    /// Fired once per track that reaches its natural end (buffer completion / YouTube `.ended`),
    /// with the song that just finished — i.e. exactly the `advanceAfterEnd()` path, never the
    /// explicit `next()`/`previous()` skip paths. Used by the TV target's play-event reporter
    /// (`markdown/appletv-servermode-plan.md` §3-2, `progress/tv-remote-play-event-client.md`) to
    /// decide when a play "counts"; `nil` on iOS/watchOS where nothing observes it. Kept as a
    /// plain closure (not a Combine/NotificationCenter broadcast) since there is currently only
    /// ever one observer.
    var onTrackNaturallyFinished: ((Song) -> Void)?

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

    // MARK: - YouTube playback backend
    //
    // `currentSong.isYouTube` picks which backend the transport controls (play/pause/seek/
    // next/previous) drive: the `AVAudioEngine` graph above for local files, or this WKWebView-
    // backed IFrame player for YouTube songs added to the Library (see `AppModel.addYouTubeSongToLibrary`).
    // `queue`/`currentIndex`/`currentSong` bookkeeping is shared across both backends so a mixed
    // queue advances seamlessly regardless of what kind the next track is.

    // tvOS has no WebKit/WKWebView (see `markdown/appletv-servermode-plan.md` Phase 1-1's
    // explicit note: "tvOS にブラウザは存在しない"), so the whole YouTube embed backend is an
    // iOS/watchOS-only concern. `MusicPlayerService` is otherwise shared with the tvOS target, so
    // this block — and every other YouTube call site below — is guarded out on tvOS rather than
    // split into a separate type (TV never receives a `song.isYouTube == true` track in Phase 1).
    #if !os(tvOS)
    /// Injected by `AppModel`: resolves a YouTube `Song` (via `sourceURL`/`path`) to an 11-char
    /// video ID using the desktop's `resolveYouTubeVideo` LAN endpoint. `nil` on failure.
    var resolveYouTubeVideoID: (@MainActor (Song) async -> String?)?

    /// Owns the single, long-lived `WKWebView` for YouTube playback. Kept alive for the app
    /// process's lifetime (not tied to `NowPlayingView`'s presentation) so a YouTube song keeps
    /// playing after the user navigates back to the Library — the same as a local file continuing
    /// via `AVAudioEngine`. SwiftUI only ever borrows `youtubePlaybackHost.webView` for display
    /// (see `YouTubeEmbedHostContainerView`).
    let youtubePlaybackHost = YouTubePlaybackHost()
    private var applicationDidEnterBackgroundObserver: NSObjectProtocol?
    private var applicationWillEnterForegroundObserver: NSObjectProtocol?
    let networkCostMonitor = NetworkCostMonitor()
    /// Whether the user has enabled low-quality YouTube playback on cellular data.
    var youtubeLowQualityOnCellular = true {
        didSet {
            guard youtubeLowQualityOnCellular != oldValue else { return }
            updateYouTubeLowQuality()
        }
    }
    private var effectiveYouTubeLowQuality = false
    /// Video ID for the currently-loading/playing YouTube song, or `nil` when idle or resolution failed.
    private(set) var currentYouTubeVideoID: String?
    /// Set when `resolveYouTubeVideoID` fails or the embed player reports an error — surfaced by `NowPlayingView`.
    private(set) var youtubePlaybackErrorMessage: String?
    /// How `NowPlayingView` should let the user recover from `youtubePlaybackErrorMessage` — see
    /// `YouTubeEmbedPlayer.EmbedFallback`. `.openInYouTubeApp` for error 101/150 (embedding
    /// disallowed on mobile; see `progress/mobile-youtube-embed.md` フェーズC), `.none` otherwise.
    private(set) var youtubePlaybackErrorFallback: YouTubeEmbedPlayer.EmbedFallback = .none
    /// Video ID captured at the moment an embed-restricted error fires, kept around so the
    /// "YouTube で開く" button still knows which video to open even though `currentYouTubeVideoID`
    /// is cleared to switch `NowPlayingView` away from the (now non-functional) embed WebView.
    private(set) var youtubePlaybackErrorVideoID: String?
    /// Transient "スキップしました" style message shown briefly in `NowPlayingView` right after an
    /// embed-restricted error auto-advances the queue to the next track. `nil` most of the time.
    private(set) var youtubePlaybackJustSkippedMessage: String?
    /// Bumped on every `loadAndPlayYouTube`/backend switch so a bridge event from a superseded video is ignored.
    private var youtubePlaybackGeneration: UInt64 = 0
    /// Tracks the app lifecycle for deterministic handling of remote commands delivered in the background.
    private var isAppInBackground = false
    /// Set when a YouTube play request must wait for the app to return to the foreground.
    private var youtubeResumePendingAfterBackground = false
    private var youtubeResumeGeneration: UInt64?
    /// Generation of a playing YouTube track that should resume after its foreground PiP exit.
    private var youtubeResumeAfterPictureInPictureExitGeneration: UInt64?
    private var youtubePictureInPictureExitModeObserved = false
    private var youtubePictureInPictureExitCommandReturned = false
    private var youtubePictureInPictureExitPauseObserved = false
    private var youtubePictureInPictureActive = false
    private var youtubePictureInPictureAvailable = false
    private var youtubeFullscreenActive = false
    private var youtubeFullscreenAvailable = false

    var isYouTubePictureInPictureActive: Bool {
        youtubePictureInPictureActive
    }

    var canUseYouTubePictureInPicture: Bool {
        youtubePictureInPictureAvailable
    }

    var isYouTubeFullscreenActive: Bool {
        youtubeFullscreenActive
    }

    var canUseYouTubeFullscreen: Bool {
        youtubeFullscreenAvailable
    }
    /// Caches `resolveYouTubeVideoID(song)` results by song id so replaying the same Library song
    /// does not re-hit the desktop's `resolveYouTubeVideo` LAN endpoint every time.
    private var youtubeVideoIDCache: [String: String] = [:]
    #endif

    #if DEBUG
    /// Sets transport/track state directly, bypassing `AVAudioEngine`, so screens can be rendered
    /// with rich fake data for screenshot verification (`UXTV_PREVIEW`, see `UXMusicTVApp` and
    /// `progress/tvos-design.md`) without touching the network or real playback. DEBUG-only.
    func configureForPreview(song: Song, isPlaying: Bool, positionSeconds: Double, durationSeconds: Double) {
        self.currentSong = song
        self.isPlaying = isPlaying
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }
    #endif

    // MARK: - External playback bridging (Task A stream-first path, tvOS)
    //
    // `TVSongStreamController`'s stream-first path (`progress/tvos-playback.md` "Now Playing
    // 統合" 追記) decodes and plays audio through its OWN dedicated `AVAudioEngine`
    // (`TVRelayStreamPlayer`), never through this service's engine — see
    // `TVRelayStreamPlayer`'s "Engine choice" doc comment for why a second engine was kept rather
    // than reusing this one. But `TVNowPlayingView` (shared with iOS/watchOS) reads title/artwork/
    // progress/transport EXCLUSIVELY from this service's `currentSong`/`isPlaying`/`positionSeconds`
    // — without this bridge, the Now Playing screen would show nothing during a streamed play even
    // though audio is audibly playing. This section lets `TVPlaybackController` mirror the
    // streaming song's metadata/progress into this service and re-route transport commands to the
    // stream, without ever touching `AVAudioEngine`/the YouTube backend for a song that has no
    // local file yet.

    /// True while an external stream (`TVSongStreamController`) — not this service's own
    /// `AVAudioEngine`/YouTube backend — is producing the audio for `currentSong`. Checked first by
    /// every transport entry point below so a Now Playing tap during streaming is routed to
    /// `externalPlaybackCommandHandler` instead of falling through to `loadAndPlay`/YouTube paths
    /// that have nothing loaded for a song that only exists as a live stream.
    private(set) var isExternallyDriven = false

    enum ExternalPlaybackCommand {
        case togglePlayPause
        case next
        case previous
        case stop
    }

    /// Set by the external stream's owner (`TVPlaybackController`) before `beginExternalPlayback`
    /// and cleared by `endExternalPlayback`. Receives transport commands raised while
    /// `isExternallyDriven` is true.
    var externalPlaybackCommandHandler: ((ExternalPlaybackCommand) -> Void)?

    /// Starts mirroring an external stream's metadata into `currentSong`/`isPlaying`/
    /// `durationSeconds` for the shared Now Playing UI. Deliberately does NOT touch
    /// `queue`/`currentIndex` — the caller owns queue advancement for the streaming path (see
    /// `TVPlaybackController.advanceAfterStreamEnd`).
    ///
    /// Invariant enforced here: "externally driven ⟹ local engine silent"
    /// (`progress/tv-cached-to-stream-switch-seekbar.md`). This is an entry point into external
    /// mirroring exactly like `play(_:newQueue:)` is an entry point into local playback, so it
    /// must bump `playGeneration` (kills any in-flight `loadAndPlay` per the generation-guard
    /// discipline documented on `playGeneration`) AND stop the local `AVAudioEngine`/YouTube
    /// backend BEFORE flipping `isExternallyDriven`. Without this, a switch from a cached
    /// (locally-playing) song to a non-cached (streamed) song left the old song's engine running:
    /// its audio kept rendering, and `tickPlaybackPosition()`'s 250ms timer kept overwriting
    /// `positionSeconds` from the stale local timeline in a fight with the stream's own
    /// `updateExternalPlaybackProgress` mirror — the reported "seek bar oscillates / can't stop
    /// playback" bug.
    func beginExternalPlayback(song: Song, durationSeconds: Double) {
        playGeneration.bump()
        stopLocalPlaybackEngineOnly()
        #if !os(tvOS)
        stopYouTubeBackend()
        #endif
        currentSong = song
        isPlaying = true
        positionSeconds = 0
        self.durationSeconds = durationSeconds
        isExternallyDriven = true
    }

    /// Called periodically by the stream's owner as the track advances — there is no local
    /// `AVAudioEngine` timeline to derive this from during streaming, so the caller polls
    /// `TVRelayStreamPlayer.elapsedSeconds` and pushes it in.
    func updateExternalPlaybackProgress(seconds: Double) {
        guard isExternallyDriven else { return }
        positionSeconds = min(max(0, seconds), durationSeconds > 0 ? durationSeconds : seconds)
    }

    /// Mirrors the stream's actual paused/playing state (e.g. after `.togglePlayPause` is routed
    /// back out and handled) so `TVNowPlayingView`'s play/pause icon stays correct.
    func setExternalPlaybackIsPlaying(_ playing: Bool) {
        guard isExternallyDriven else { return }
        isPlaying = playing
    }

    /// Ends external mirroring. Does not itself clear `currentSong` — the caller decides what (if
    /// anything) replaces it next: a natural end/failure falls through to `TVPlaybackController`
    /// advancing the queue (a fresh `beginExternalPlayback`/`play` call), an explicit stop calls
    /// `stop()` below.
    func endExternalPlayback() {
        isExternallyDriven = false
        externalPlaybackCommandHandler = nil
    }

    /// Audio session activation is deferred until playback starts to keep app launch light.
    private var playbackSessionPrepared = false
    private let sessionActivationLock = NSLock()

    private var lastPublishedNowPlayingSongId: String?
    private var artworkLoadedForSongId: String?
    private var artworkInFlightForSongId: String?
    private var nowPlayingArtworkImage: UIImage?

    // MARK: - Engine graph / timeline

    /// True while the local `AVAudioEngine` graph has a track loaded — i.e. before
    /// `beginExternalPlayback`/`stopLocalPlaybackEngineOnly`/`stop()` clear it. Test seam only
    /// (precedent: `TVRelayStreamPlayer.isRenderActiveForTesting`), used to assert the "externally
    /// driven ⟹ local engine silent" invariant from outside the type.
    var hasActiveLocalAudioFileForTesting: Bool { currentAudioFile != nil }
    var isPositionTimerRunningForTesting: Bool { positionTimer != nil }
    var lastNowPlayingPublicationIsPlayingForTesting: Bool? { lastNowPlayingPublication?.isPlaying }
    var normalisationGainDecibelsForTesting: Float { normalisationUnit.globalGain }
    var masterOutputVolumeForTesting: Float { engine.mainMixerNode.outputVolume }
    var normalisationIsInSignalPathForTesting: Bool {
        engine.outputConnectionPoints(for: equaliserUnit, outputBus: 0).contains { $0.node === normalisationUnit }
            && engine.outputConnectionPoints(for: normalisationUnit, outputBus: 0).contains { $0.node === engine.mainMixerNode }
            && !normalisationUnit.bypass
    }

    private var currentAudioFile: AVAudioFile?
    private var scheduledSegmentStartFrame: AVAudioFramePosition = 0
    private var frozenPositionWhilePaused: Double?
    private var lastWireFormat: AVAudioFormat?
    private var nodesAttached = false

    /// Bumped whenever we `stop()` the player node for a reason other than natural buffer completion.
    /// Completion handlers from superseded schedules must not call `advanceAfterEnd()` (avoids queue storms after route changes).
    private var playbackCompletionGeneration: UInt64 = 0

    /// Bumped synchronously — before any `await` — at the top of every entry point that leads to
    /// `loadAndPlay`/`loadActive` (`play(_:newQueue:)`, `next()`, `previous()`, `playQueueItem(at:)`,
    /// `togglePlayPause()`'s resume-from-idle branch, `remoteResumeAfterPlayCommand()`) and by
    /// `stop()`. `loadAndPlay` re-checks its captured token with `playGeneration.isCurrent(_:)` after
    /// every suspension point before touching `currentAudioFile`, the player node, the engine graph,
    /// or published position state — so a call overtaken by a later one (or by an explicit `stop()`)
    /// bails out instead of clobbering the newer state. See `PlaybackGenerationGuard`.
    private var playGeneration = PlaybackGenerationGuard()

    init(collectionShufflePreferenceStore: CollectionShufflePreferenceStore? = nil) {
        self.collectionShufflePreferenceStore = collectionShufflePreferenceStore ?? CollectionShufflePreferenceStore()
        configureEqualiserBandsStatically()
        pushEqualiserToAudioUnit()
        loadEqualiserStateFromUserDefaults()
        loadPlaybackModesFromUserDefaults()
        addAudioInterruptionObserver()
        addAudioRouteChangeObserver()
        installRemoteCommandHandlers()
        #if !os(tvOS)
        youtubePlaybackHost.onEvent = { [weak self] event in
            self?.handleYouTubeBridgeEvent(event)
        }
        youtubePlaybackHost.onPictureInPictureModeChange = { [weak self] mode in
            guard let self else { return }
            let wasPictureInPictureActive = self.youtubePictureInPictureActive
            let wasFullscreenActive = self.youtubeFullscreenActive
            self.youtubePictureInPictureAvailable = self.currentSong?.isYouTube == true
                && self.youtubePlaybackHost.isPictureInPictureAvailable
            self.youtubeFullscreenAvailable = self.currentSong?.isYouTube == true
                && self.youtubePlaybackHost.isFullscreenAvailable
            self.youtubePictureInPictureActive = mode == .pictureInPicture
                && self.youtubePictureInPictureAvailable
            self.youtubeFullscreenActive = mode == .fullscreen
                && self.youtubeFullscreenAvailable
            NSLog(
                "[UXM_YT_PIP] availability mode=%@ currentSongIsYouTube=%d host(pip=%d fullscreen=%d) service(pip=%d fullscreen=%d)",
                String(describing: mode),
                self.currentSong?.isYouTube == true ? 1 : 0,
                self.youtubePlaybackHost.isPictureInPictureAvailable ? 1 : 0,
                self.youtubePlaybackHost.isFullscreenAvailable ? 1 : 0,
                self.youtubePictureInPictureAvailable ? 1 : 0,
                self.youtubeFullscreenAvailable ? 1 : 0
            )
            if self.youtubePictureInPictureActive && !wasPictureInPictureActive {
                NSLog("[UXM_YT_PIP] PiP entered")
            } else if wasPictureInPictureActive && !self.youtubePictureInPictureActive {
                NSLog("[UXM_YT_PIP] PiP exited")
            }
            if mode == .inline {
                self.youtubePictureInPictureExitModeObserved = true
                self.resumeYouTubeAfterPictureInPictureExitIfNeeded()
            }
            if self.youtubeFullscreenActive && !wasFullscreenActive {
                NSLog("[UXM_YT_PIP] fullscreen entered")
            } else if wasFullscreenActive && !self.youtubeFullscreenActive {
                NSLog("[UXM_YT_PIP] fullscreen exited")
            }
            self.updateNowPlayingCentre()
        }
        networkCostMonitor.onCellularStatusChange = { [weak self] _ in
            self?.updateYouTubeLowQuality()
        }
        addYouTubeAppLifecycleObservers()
        updateYouTubeLowQuality()
        #endif
    }

    /// Invalidates pending `scheduleFile` / `scheduleSegment` completion callbacks before the next `playerNode.stop()`.
    private func bumpPlaybackCompletionGeneration() {
        playbackCompletionGeneration &+= 1
    }

    private func makeScheduleCompletionHandler() -> AVAudioNodeCompletionHandler {
        let generationWhenScheduled = playbackCompletionGeneration
        return { [weak self] in
            Task { @MainActor in
                await self?.handleScheduledBufferCompletion(generationWhenScheduled: generationWhenScheduled)
            }
        }
    }

    private func handleScheduledBufferCompletion(generationWhenScheduled: UInt64) async {
        guard generationWhenScheduled == playbackCompletionGeneration else { return }
        await advanceAfterEnd()
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
        activateSessionIfNeededSync()
    }

    /// Thread-safe, synchronous session activation (remote commands and `seek` run on an arbitrary queue).
    private func activateSessionIfNeededSync() {
        sessionActivationLock.lock()
        defer { sessionActivationLock.unlock() }
        guard !playbackSessionPrepared else { return }
        if activateSharedAudioSessionForPlayback() {
            playbackSessionPrepared = true
        }
    }

    /// Runs `body` on the main actor and returns only after it finishes (avoids `.success` before Now Playing updates).
    nonisolated private func dispatchToMainSync(_ body: @MainActor () -> MPRemoteCommandHandlerStatus) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        var result = MPRemoteCommandHandlerStatus.commandFailed
        DispatchQueue.main.sync {
            result = MainActor.assumeIsolated { body() }
        }
        return result
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

    /// The 4 Hz position timer exists only while `isPlaying` is true (driven by its `didSet`):
    /// running it for the whole process lifetime kept the CPU and the media-server IPC busy while
    /// paused, stopped or empty. External (tvOS stream) playback also sets `isPlaying`, so it
    /// keeps ticking too.
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

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    /// With the timer stopped on pause, `positionSeconds` could lag the real (frozen) position by up
    /// to one tick. Refresh it once after the pause state has settled and republish.
    private func settlePositionAfterPause() {
        Task { @MainActor [weak self] in
            guard let self, !self.isPlaying, self.currentSong != nil else { return }
            // Externally driven playback owns `positionSeconds`; only local playback recomputes it.
            if !self.isExternallyDriven, self.currentAudioFile != nil {
                let pos = self.currentTimelineSeconds()
                self.positionSeconds = self.durationSeconds > 0
                    ? min(max(0, pos), self.durationSeconds) : max(0, pos)
            }
            self.updateNowPlayingCentre()
        }
    }

    private func tickPlaybackPosition() {
        guard currentSong != nil else { return }
        // While externally driven, `updateExternalPlaybackProgress(seconds:)` is the single writer
        // of `positionSeconds` (see the invariant documented on `beginExternalPlayback`) — the
        // local timeline is stale/irrelevant here, so this must not recompute/overwrite it. Still
        // refresh Now Playing metadata (title/artwork) so the lock screen keeps updating.
        guard !isExternallyDriven else {
            updateNowPlayingCentre(force: false)
            return
        }
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
        // Do NOT call syncIsPlayingFromNode() here: the timer must not override the
        // intentional isPlaying state set by explicit play/pause actions.
        updateNowPlayingCentre(force: false)
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

    /// Starts playing `song` from `newQueue`. `startIndex` is the caller's row index for `song` in
    /// `newQueue`; when it is in range and names `song`, that exact copy starts, so a song listed
    /// more than once plays from the row that was tapped. Without it, the first copy is used.
    func play(
        _ song: Song,
        newQueue: [Song],
        collection: PlaybackCollectionRef? = nil,
        startIndex: Int? = nil
    ) async {
        let generation = playGeneration.bump()
        // A previous stream-first session may still be marked external (e.g. the cache finished
        // downloading mid-stream and `TVPlaybackController` now hands off to the normal cached
        // path) — this service's own engine is about to take over, so external mirroring must end
        // first or `togglePlayPause`/`next`/`previous` below would keep routing to a stream that's
        // no longer relevant.
        if isExternallyDriven {
            isExternallyDriven = false
            externalPlaybackCommandHandler = nil
        }
        let preference = collection.flatMap { collectionShufflePreferenceStore.preference(for: $0) }
        let effectiveShuffleEnabled = PlaybackCollectionShuffleLogic.effectiveShuffleEnabled(
            baselineShuffleEnabled: baselineShuffleEnabled,
            preference: preference
        )
        let chosenStart: Int? = startIndex.flatMap { index in
            newQueue.indices.contains(index) && newQueue[index].id == song.id ? index : nil
        }
        if effectiveShuffleEnabled {
            originalQueue = newQueue
            var indices = Array(newQueue.indices).shuffled()
            if let chosenStart {
                // Moving the chosen copy to the front makes `applyShuffle` pin that exact copy as current.
                indices.removeAll { $0 == chosenStart }
                indices.insert(chosenStart, at: 0)
            }
            queue = PlaybackShuffleLogic.applyShuffle(queue: newQueue, shuffledIndices: indices, currentId: song.id)
        } else {
            originalQueue = []
            queue = newQueue
        }
        isShuffleEnabled = effectiveShuffleEnabled
        if let chosenStart, !effectiveShuffleEnabled {
            currentIndex = chosenStart
        } else if let idx = queue.firstIndex(where: { $0.id == song.id }) {
            currentIndex = idx
        } else {
            queue.append(song)
            currentIndex = queue.count - 1
        }
        let active = queue[currentIndex]
        currentSong = active
        await loadActive(active, generation: generation)
    }

    func togglePlayPause() {
        if isExternallyDriven {
            externalPlaybackCommandHandler?(.togglePlayPause)
            return
        }
        let generation = playGeneration.bump()
        Task { @MainActor [weak self] in
            guard let self else { return }
            #if !os(tvOS)
            if let song = self.currentSong, song.isYouTube {
                self.toggleYouTubePlayPause()
                return
            }
            #endif
            self.activateSessionIfNeededSync()
            if self.playerNode.isPlaying {
                self.frozenPositionWhilePaused = self.currentTimelineSeconds()
                self.playerNode.pause()
                self.engine.stop()  // Stop the engine so iOS audio session goes idle;
                // otherwise iOS may override playbackState=.paused with .playing
                // because it sees the running AVAudioEngine as "active audio".
            } else if self.currentAudioFile != nil {
                self.resumeLocalPlaybackAfterPause()
            } else if let song = self.currentSong {
                await self.loadAndPlay(song, generation: generation)
            }
            self.syncIsPlayingFromNode()
            self.updateNowPlayingCentre()
        }
    }

    /// Explicit "skip forward" (UI button / remote command) — always wraps to the start of the
    /// queue, regardless of `repeatMode` (classic media-player behaviour; only the *natural end of
    /// track* path in `advanceAfterEnd()` respects "stop when repeat is off").
    func next() async {
        if isExternallyDriven {
            externalPlaybackCommandHandler?(.next)
            return
        }
        let generation = playGeneration.bump()
        guard !queue.isEmpty else { return }
        currentIndex = PlaybackQueueNavigation.nextIndex(current: currentIndex, count: queue.count)
        let s = queue[currentIndex]
        currentSong = s
        await loadActive(s, generation: generation)
    }

    /// Explicit "skip back" — restarts the current track if more than a few seconds in, otherwise
    /// wraps to the end of the queue (same wrap-always rule as `next()`).
    func previous() async {
        if isExternallyDriven {
            externalPlaybackCommandHandler?(.previous)
            return
        }
        let generation = playGeneration.bump()
        guard !queue.isEmpty else { return }
        if PlaybackQueueNavigation.shouldRestartOnPrevious(position: positionSeconds) {
            seek(to: 0)
        } else {
            currentIndex = PlaybackQueueNavigation.previousIndex(current: currentIndex, count: queue.count)
            let s = queue[currentIndex]
            currentSong = s
            await loadActive(s, generation: generation)
        }
    }

    /// Jumps to a track already present in the queue and starts playback.
    func playQueueItem(at index: Int) async {
        guard index >= 0, index < queue.count else { return }
        let generation = playGeneration.bump()
        currentIndex = index
        let s = queue[currentIndex]
        currentSong = s
        await loadActive(s, generation: generation)
    }

    /// Routes to the local `AVAudioEngine` path or the YouTube embed backend depending on `song.isYouTube`,
    /// stopping whichever backend is not needed so the two never play simultaneously.
    private func loadActive(_ song: Song, generation: UInt64) async {
        #if !os(tvOS)
        if song.isYouTube {
            stopLocalPlaybackEngineOnly()
            await loadAndPlayYouTube(song)
        } else {
            stopYouTubeBackend()
            await loadAndPlay(song, generation: generation)
        }
        #else
        // TV is never handed a YouTube track in Phase 1 (see `markdown/appletv-servermode-plan.md`
        // — relay-only in Phase 3), so the local `AVAudioEngine` path is unconditional here.
        await loadAndPlay(song, generation: generation)
        #endif
    }

    /// - Parameter resumeAfterSeek: When `nil`, keeps playing iff the node was already playing (scrub-while-paused stays paused).
    func seek(to seconds: Double, resumeAfterSeek: Bool? = nil) {
        #if !os(tvOS)
        if let song = currentSong, song.isYouTube {
            youtubePlaybackHost.send(.seek(seconds: seconds))
            positionSeconds = min(max(0, seconds), durationSeconds > 0 ? durationSeconds : seconds)
            updateNowPlayingCentre()
            return
        }
        #endif
        guard let file = currentAudioFile else { return }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return }
        let length = file.length
        let frame = AVAudioFramePosition(seconds * sr)
        let start = min(max(0, frame), max(length - 1, 0))
        let remaining = AVAudioFrameCount(max(0, length - start))

        let shouldResume = resumeAfterSeek ?? playerNode.isPlaying
        bumpPlaybackCompletionGeneration()
        playerNode.stop()
        frozenPositionWhilePaused = nil
        scheduledSegmentStartFrame = start
        positionSeconds = Double(start) / sr

        let completion = makeScheduleCompletionHandler()

        if remaining > 0 {
            playerNode.scheduleSegment(file, startingFrame: start, frameCount: remaining, at: nil, completionHandler: completion)
        }
        if shouldResume {
            ensureEngineRunning()
            playerNode.play()
        } else {
            frozenPositionWhilePaused = Double(start) / sr
        }
        syncIsPlayingFromNode()
        updateNowPlayingCentre()
    }

    func stop() {
        playGeneration.bump()
        if isExternallyDriven {
            externalPlaybackCommandHandler?(.stop)
            isExternallyDriven = false
            externalPlaybackCommandHandler = nil
        }
        stopLocalPlaybackEngineOnly()
        #if !os(tvOS)
        stopYouTubeBackend()
        #endif
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

    /// Stops the `AVAudioEngine` graph without touching `queue`/`currentSong` — used when switching
    /// the active backend to YouTube for the current track (see `loadActive`).
    private func stopLocalPlaybackEngineOnly() {
        bumpPlaybackCompletionGeneration()
        playerNode.stop()
        engine.stop()
        currentAudioFile = nil
        scheduledSegmentStartFrame = 0
        frozenPositionWhilePaused = nil
        lastWireFormat = nil
    }

    // MARK: - YouTube playback backend
    //
    // Whole block excluded on tvOS — no WebKit there (see the `#if !os(tvOS)` note further up
    // this file). `handleYouTubeBridgeEvent`/`openYouTubePlaybackErrorInYouTubeApp` are called
    // from `NowPlayingView`, which is iOS/watchOS-only UI; the tvOS Now Playing UI lands in
    // Phase 2 and will not call these.
    #if !os(tvOS)

    private func addYouTubeAppLifecycleObservers() {
        applicationDidEnterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleYouTubeDidEnterBackground()
            }
        }
        applicationWillEnterForegroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleYouTubeWillEnterForeground()
            }
        }
    }

    private func handleYouTubeDidEnterBackground() {
        isAppInBackground = true
        let decision = YouTubeBackgroundResumePolicy.onEnterBackground(
            isYouTubeSong: currentSong?.isYouTube == true,
            isPlaying: isPlaying,
            presentationMode: youtubePlaybackHost.pictureInPictureMode
        )
        switch decision {
        case .noAction:
            clearYouTubeResumePending()
        case .keepPlaying:
            clearYouTubeResumePending()
            NSLog(
                "[UXM_YT_PIP] background decision=keepPlaying mode=%@",
                String(describing: youtubePlaybackHost.pictureInPictureMode)
            )
        case .pauseAndResume:
            NSLog(
                "[UXM_YT_PIP] background decision=fallback mode=%@",
                String(describing: youtubePlaybackHost.pictureInPictureMode)
            )
            useYouTubeBackgroundFallback()
        }
    }

    private func handleYouTubeWillEnterForeground() {
        isAppInBackground = false
        let decision = YouTubeBackgroundResumePolicy.onEnterForeground(
            resumePending: youtubeResumePendingAfterBackground,
            isYouTubeSong: currentSong?.isYouTube == true,
            isPlaying: isPlaying,
            presentationMode: youtubePlaybackHost.pictureInPictureMode
        )
        if decision.resumeAfterPictureInPictureExit {
            prepareYouTubeResumeAfterPictureInPictureExit()
        } else {
            clearYouTubeResumeAfterPictureInPictureExit()
        }
        if decision.exitPictureInPicture {
            requestYouTubePictureInPictureExit(reason: "foreground")
        }
        let shouldResume = decision.resumePlayback && youtubeResumeGeneration == youtubePlaybackGeneration
        clearYouTubeResumePending()
        if shouldResume {
            youtubePlaybackHost.send(.play)
        }
    }

    private func useYouTubeBackgroundFallback() {
        NSLog("[UXM_YT_PIP] fallback used: pause and resume on foreground")
        youtubePlaybackHost.send(.pause)
        isPlaying = false
        youtubeResumePendingAfterBackground = true
        youtubeResumeGeneration = youtubePlaybackGeneration
        updateNowPlayingCentre()
    }

    private func requestYouTubePictureInPictureExit(reason: String) {
        guard youtubePlaybackHost.pictureInPictureMode == .pictureInPicture else { return }
        NSLog("[UXM_YT_PIP] exiting reason=%@", reason)
        let generation = youtubePlaybackGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.youtubePlaybackHost.exitPictureInPicture()
            guard generation == self.youtubePlaybackGeneration else { return }
            self.youtubePictureInPictureExitCommandReturned = true
            self.resumeYouTubeAfterPictureInPictureExitIfNeeded()
        }
    }

    private func requestYouTubeFullscreenExit(reason: String) {
        guard youtubePlaybackHost.pictureInPictureMode == .fullscreen else { return }
        NSLog("[UXM_YT_PIP] exiting fullscreen reason=%@", reason)
        Task { @MainActor [weak self] in
            await self?.youtubePlaybackHost.exitFullscreen()
        }
    }

    private func clearYouTubeResumePending() {
        youtubeResumePendingAfterBackground = false
        youtubeResumeGeneration = nil
    }

    private func prepareYouTubeResumeAfterPictureInPictureExit() {
        youtubeResumeAfterPictureInPictureExitGeneration = youtubePlaybackGeneration
        youtubePictureInPictureExitModeObserved = false
        youtubePictureInPictureExitCommandReturned = false
        youtubePictureInPictureExitPauseObserved = false
    }

    private func clearYouTubeResumeAfterPictureInPictureExit() {
        youtubeResumeAfterPictureInPictureExitGeneration = nil
        youtubePictureInPictureExitModeObserved = false
        youtubePictureInPictureExitCommandReturned = false
        youtubePictureInPictureExitPauseObserved = false
    }

    private func resumeYouTubeAfterPictureInPictureExitIfNeeded() {
        guard let generation = youtubeResumeAfterPictureInPictureExitGeneration,
              generation == youtubePlaybackGeneration,
              currentSong?.isYouTube == true,
              youtubePictureInPictureExitPauseObserved,
              youtubePictureInPictureExitModeObserved || youtubePictureInPictureExitCommandReturned
        else { return }
        clearYouTubeResumeAfterPictureInPictureExit()
        youtubePlaybackHost.send(.play)
        isPlaying = true
        updateNowPlayingCentre()
    }

    /// Defers a YouTube play request until foreground because WebKit cannot resume this video in
    /// the background; see `mobile_youtube_background_research/notes/background-pause.md`.
    private func deferYouTubePlayUntilForeground() {
        youtubeResumePendingAfterBackground = true
        youtubeResumeGeneration = youtubePlaybackGeneration
        isPlaying = false
        updateNowPlayingCentre()
    }

    private func requestYouTubePlay() {
        if isAppInBackground {
            switch YouTubeBackgroundResumePolicy.onRemotePlayWhileBackgrounded(
                isYouTubeSong: true,
                isPictureInPictureActive: youtubePictureInPictureActive
            ) {
            case .deferUntilForeground:
                deferYouTubePlayUntilForeground()
                return
            case .playNow:
                break
            }
        }
        clearYouTubeResumePending()
        clearYouTubeResumeAfterPictureInPictureExit()
        youtubePlaybackHost.send(.play)
        isPlaying = true
        updateNowPlayingCentre()
    }

    private func pauseYouTubeAndClearResumePending() {
        youtubePlaybackHost.send(.pause)
        clearYouTubeResumePending()
        clearYouTubeResumeAfterPictureInPictureExit()
        isPlaying = false
        updateNowPlayingCentre()
    }

    /// Stops the embed player without touching `queue`/`currentSong` — used when switching the
    /// active backend to local playback, and from `stop()`. The `WKWebView` itself is not
    /// destroyed (see `YouTubePlaybackHost`) — only paused and returned inline.
    private func stopYouTubeBackend() {
        youtubePlaybackGeneration &+= 1
        clearYouTubeResumeAfterPictureInPictureExit()
        requestYouTubePictureInPictureExit(reason: "backend stopped")
        requestYouTubeFullscreenExit(reason: "backend stopped")
        youtubePlaybackHost.send(.pause)
        youtubePictureInPictureActive = false
        youtubePictureInPictureAvailable = false
        youtubeFullscreenActive = false
        youtubeFullscreenAvailable = false
        currentYouTubeVideoID = nil
        youtubePlaybackErrorMessage = nil
        youtubePlaybackErrorFallback = .none
        youtubePlaybackErrorVideoID = nil
        // Deliberately NOT clearing `youtubePlaybackJustSkippedMessage` here: this is called as
        // part of switching to the next queue item (see `loadActive`), which is exactly when an
        // embed-restriction auto-skip (`scheduleAutoSkipAfterEmbedRestriction`) wants its "スキップ
        // しました" toast to actually be visible for a moment on the new track. It clears itself
        // via its own short timer instead.
    }

    /// Loads and plays `song` on the persistent `youtubePlaybackHost` directly — independent of
    /// whether any SwiftUI view currently displays `youtubePlaybackHost.webView` (see that type's
    /// doc comment). `currentYouTubeVideoID` only reflects what is loaded for display purposes.
    private func loadAndPlayYouTube(_ song: Song) async {
        await preparePlaybackSessionIfNeeded()
        youtubePlaybackGeneration &+= 1
        clearYouTubeResumeAfterPictureInPictureExit()
        let generation = youtubePlaybackGeneration
        currentYouTubeVideoID = nil
        youtubePlaybackErrorMessage = nil
        youtubePlaybackErrorFallback = .none
        youtubePlaybackErrorVideoID = nil
        // See the comment in `stopYouTubeBackend()` for why `youtubePlaybackJustSkippedMessage`
        // is deliberately left alone here.
        positionSeconds = 0
        durationSeconds = song.duration > 0 ? song.duration : 0
        isPlaying = true
        updateNowPlayingCentre()

        let videoID: String
        if let cached = youtubeVideoIDCache[song.id] {
            videoID = cached
        } else {
            guard let resolver = resolveYouTubeVideoID, let resolved = await resolver(song) else {
                guard generation == youtubePlaybackGeneration else { return }
                isPlaying = false
                youtubePlaybackErrorMessage = String(localized: "Couldn't fetch video info. Check the pairing status with the desktop.")
                updateNowPlayingCentre()
                return
            }
            videoID = resolved
            youtubeVideoIDCache[song.id] = resolved
        }
        guard generation == youtubePlaybackGeneration else { return }

        youtubePlaybackHost.setLowQuality(effectiveYouTubeLowQuality)
        do {
            try await youtubePlaybackHost.load(videoID: videoID, lowQuality: effectiveYouTubeLowQuality)
        } catch {
            guard generation == youtubePlaybackGeneration else { return }
            isPlaying = false
            youtubePlaybackErrorMessage = YouTubeEmbedPlayer.errorMessage(code: -1)
            updateNowPlayingCentre()
            return
        }
        guard generation == youtubePlaybackGeneration else { return }
        // `playerVars.autoplay = 1` (see `YouTubeEmbedPlayer`) starts playback once the IFrame API
        // reports `onReady` — no explicit `.play` command needed here.
        currentYouTubeVideoID = videoID
    }

    private func toggleYouTubePlayPause() {
        if isPlaying {
            pauseYouTubeAndClearResumePending()
        } else {
            requestYouTubePlay()
        }
    }

    /// Toggles the current YouTube video between inline and system PiP presentation.
    func toggleYouTubePictureInPicture() {
        guard currentSong?.isYouTube == true else { return }
        if youtubePictureInPictureActive {
            requestYouTubePictureInPictureExit(reason: "user toggle")
            return
        }
        guard youtubePlaybackHost.isPictureInPictureAvailable else {
            NSLog("[UXM_YT_PIP] unavailable reason=pictureInPicture")
            return
        }
        NSLog("[UXM_YT_PIP] entering trigger=user toggle")
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.youtubePlaybackHost.enterPictureInPicture() else {
                NSLog("[UXM_YT_PIP] PiP failed trigger=user toggle")
                return
            }
        }
    }

    /// Enters native fullscreen so a home swipe can transition the WebKit video to system PiP;
    /// see `mobile_youtube_background_research/notes/background-pause.md` §C-1 and §フェーズH.
    func enterYouTubeFullscreen() {
        guard currentSong?.isYouTube == true else { return }
        guard youtubeFullscreenAvailable else {
            NSLog("[UXM_YT_PIP] fullscreen unavailable")
            return
        }
        NSLog("[UXM_YT_PIP] entering fullscreen")
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.youtubePlaybackHost.enterFullscreen() else {
                NSLog("[UXM_YT_PIP] fullscreen failed")
                return
            }
        }
    }

    /// Routes IFrame Player API events (via `YouTubePlaybackHost.onEvent`) into the unified
    /// transport state.
    func handleYouTubeBridgeEvent(_ event: YouTubeEmbedPlayer.BridgeEvent) {
        guard let song = currentSong, song.isYouTube else { return }
        switch event {
        case .ready:
            youtubePlaybackHost.setLowQuality(effectiveYouTubeLowQuality)
            youtubePlaybackHost.send(.unmute)
        case .state(.playing):
            if youtubePictureInPictureExitModeObserved {
                clearYouTubeResumeAfterPictureInPictureExit()
            }
            isPlaying = true
            youtubePlaybackErrorMessage = nil
            updateNowPlayingCentre()
        case .state(.paused):
            // A user closing the system PiP window also produces this event and must not auto-resume
            // in the background. A foreground PiP exit may resume only after this pause is observed.
            isPlaying = false
            if youtubeResumeAfterPictureInPictureExitGeneration != nil {
                if youtubePictureInPictureExitModeObserved || youtubePictureInPictureExitCommandReturned {
                    youtubePictureInPictureExitPauseObserved = true
                    resumeYouTubeAfterPictureInPictureExitIfNeeded()
                } else {
                    clearYouTubeResumeAfterPictureInPictureExit()
                }
            }
            updateNowPlayingCentre()
        case .state(.ended):
            clearYouTubeResumeAfterPictureInPictureExit()
            isPlaying = false
            updateNowPlayingCentre()
            Task { @MainActor [weak self] in
                await self?.advanceAfterEnd()
            }
        case .time(let current, let duration):
            positionSeconds = current
            if duration > 0 { durationSeconds = duration }
            updateNowPlayingCentre(force: false)
        case .error(let code):
            isPlaying = false
            youtubePlaybackErrorMessage = YouTubeEmbedPlayer.errorMessage(code: code)
            let fallback = YouTubeEmbedPlayer.embedFallback(forErrorCode: code)
            youtubePlaybackErrorFallback = fallback
            if fallback == .openInYouTubeApp {
                // The embed WebView is not going to recover from this (see
                // `progress/mobile-youtube-embed.md` フェーズC: this is a genuine YouTube-side
                // mobile-web embedding restriction, not something a retry fixes), so stop showing
                // it in favour of the error + "YouTube で開く" UI, and let the queue move on
                // instead of stalling indefinitely on an unplayable track.
                youtubePlaybackErrorVideoID = currentYouTubeVideoID
                currentYouTubeVideoID = nil
                scheduleAutoSkipAfterEmbedRestriction(generation: youtubePlaybackGeneration)
            }
            updateNowPlayingCentre()
        default:
            break
        }
    }

    private func updateYouTubeLowQuality() {
        let nextValue = YouTubeEmbedPlayer.shouldUseLowQuality(
            isCellular: networkCostMonitor.isCellular,
            lowQualityOnCellularEnabled: youtubeLowQualityOnCellular
        )
        guard nextValue != effectiveYouTubeLowQuality else { return }
        effectiveYouTubeLowQuality = nextValue
        guard currentYouTubeVideoID != nil else { return }
        youtubePlaybackHost.setLowQuality(nextValue)
    }

    /// After an embed-restricted error (101/150), gives the user a short window to notice the
    /// "YouTube で開く" button before automatically advancing the queue — see
    /// `handleYouTubeBridgeEvent`'s `.error` case and `progress/mobile-youtube-embed.md` フェーズD.
    /// Guarded by `generation` so this no-ops if the user has already navigated away (manual
    /// next/previous, a different song loaded, playback stopped, …) by the time the delay elapses.
    private func scheduleAutoSkipAfterEmbedRestriction(generation: UInt64) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, generation == self.youtubePlaybackGeneration else { return }
            let skippedMessage = String(localized: "Skipped because embedded playback is not allowed")
            self.youtubePlaybackJustSkippedMessage = skippedMessage
            await self.advanceAfterEnd()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // Only clear it if nothing else (e.g. a later skip) has replaced it since.
                guard let self, self.youtubePlaybackJustSkippedMessage == skippedMessage else { return }
                self.youtubePlaybackJustSkippedMessage = nil
            }
        }
    }

    /// Opens the video behind the current embed-restricted error in the official YouTube app (or
    /// Safari, if the app is not installed) — called from `NowPlayingView`'s "YouTube で開く"
    /// button. Playing via the official app/site still counts the view and pays out to the
    /// creator normally, unlike any embed workaround.
    func openYouTubePlaybackErrorInYouTubeApp() {
        guard let videoID = youtubePlaybackErrorVideoID else { return }
        let appIsAvailable = URL(string: "youtube://").map { UIApplication.shared.canOpenURL($0) } ?? false
        guard let url = YouTubeEmbedPlayer.urlToOpen(forVideoID: videoID, youtubeAppIsAvailable: appIsAvailable) else { return }
        UIApplication.shared.open(url)
    }

    #endif

    /// Writes a resolver-rewritten `path` back into `currentSong` and the matching `queue` entry,
    /// so seek/route-change rescheduling (which re-reads `currentSong`/`queue`, not the local
    /// `song` passed into `loadAndPlay`) keeps using the resolved local file.
    private func updateQueueEntryPath(for song: Song) {
        if currentSong?.id == song.id {
            currentSong = song
        }
        if let idx = queue.firstIndex(where: { $0.id == song.id }) {
            queue[idx] = song
        }
    }

    private func loadAndPlay(_ song: Song, generation: UInt64) async {
        await preparePlaybackSessionIfNeeded()
        guard playGeneration.isCurrent(generation) else { return }
        await Task.yield()
        guard playGeneration.isCurrent(generation) else { return }

        var song = song
        if !FileManager.default.fileExists(atPath: song.path) {
            guard let resolver = localFileResolver, let resolved = await resolver(song) else {
                #if DEBUG
                NSLog("UXMusic: missing local file at %@", song.path)
                #endif
                return
            }
            guard playGeneration.isCurrent(generation) else { return }
            guard FileManager.default.fileExists(atPath: resolved.path) else {
                #if DEBUG
                NSLog("UXMusic: resolver returned unreadable path for %@: %@", song.id, resolved.path)
                #endif
                return
            }
            song = resolved
            updateQueueEntryPath(for: song)
        }

        let path = song.path
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

        bumpPlaybackCompletionGeneration()
        playerNode.stop()
        scheduledSegmentStartFrame = 0
        frozenPositionWhilePaused = nil
        positionSeconds = 0

        let completion = makeScheduleCompletionHandler()

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
            engine.attach(normalisationUnit)
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
            engine.disconnectNodeOutput(normalisationUnit)
        }

        engine.connect(playerNode, to: equaliserUnit, format: fmt)
        engine.connect(equaliserUnit, to: normalisationUnit, format: fmt)
        engine.connect(normalisationUnit, to: engine.mainMixerNode, format: fmt)
        lastWireFormat = fmt
        engine.prepare()
        applyLoudnessGain()
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
            applyLoudnessGain()
            try engine.start()
        }
    }

    private func syncIsPlayingFromNode() {
        let next = playerNode.isPlaying
        guard next != isPlaying else { return }
        isPlaying = next
    }

    /// After `pause()`, resumes if buffers still exist; otherwise re-seeks and plays (e.g. schedule exhausted).
    private func resumeLocalPlaybackAfterPause() {
        guard currentAudioFile != nil, currentSong != nil else { return }
        let resumeT = frozenPositionWhilePaused ?? currentTimelineSeconds()
        frozenPositionWhilePaused = nil
        ensureEngineRunning()
        playerNode.play()
        syncIsPlayingFromNode()
        if isPlaying {
            updateNowPlayingCentre()
            return
        }
        let bounded: Double = if durationSeconds > 0 {
            min(max(0, resumeT), durationSeconds)
        } else {
            max(0, resumeT)
        }
        // When the schedule was fully consumed by natural playback end (not an explicit pause),
        // `bounded` lands at or near `durationSeconds`. Re-seeking there would schedule 0 frames
        // and produce silence. Restart from the beginning instead.
        let nearEnd = durationSeconds > 0 && bounded >= durationSeconds - 0.5
        seek(to: nearEnd ? 0 : bounded, resumeAfterSeek: true)
    }

    private func remoteResumeAfterPlayCommand() -> MPRemoteCommandHandlerStatus {
        guard let song = currentSong else { return .commandFailed }
        #if !os(tvOS)
        if song.isYouTube {
            requestYouTubePlay()
            return .success
        }
        #endif
        if currentAudioFile == nil {
            let generation = playGeneration.bump()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.loadAndPlay(song, generation: generation)
            }
            // Playback will start asynchronously — tell the system the command was accepted.
            return .success
        }
        resumeLocalPlaybackAfterPause()
        return isPlaying ? .success : .commandFailed
    }

    /// Natural end-of-track (buffer completion / YouTube `.ended`) — unlike `next()`, this respects
    /// `repeatMode`: stops at the end of the queue when repeat is off (the bug this fixes — the
    /// queue previously always looped `(currentIndex + 1) % queue.count` regardless of any repeat
    /// setting), restarts the current track for repeat-one, and wraps for repeat-all.
    private func advanceAfterEnd() async {
        if let finishedSong = currentSong {
            onTrackNaturallyFinished?(finishedSong)
        }
        switch PlaybackQueueNavigation.autoAdvance(current: currentIndex, count: queue.count, repeatMode: repeatMode) {
        case .stop:
            // Sync state immediately so Now Playing reflects the paused/stopped state even when the
            // background timer is throttled by iOS.
            syncIsPlayingFromNode()
            updateNowPlayingCentre()
        case .index(let idx):
            await playQueueItem(at: idx)
        }
    }

    // MARK: - Output route changes (Control Centre, Bluetooth, AirPlay, …)

    private func addAudioRouteChangeObserver() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let info = notification.userInfo,
                let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
            else { return }

            Task { @MainActor in
                await self.handleRouteChange(reason: reason)
            }
        }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) async {
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange, .categoryChange, .override:
            break
        default:
            return
        }

        try? AVAudioSession.sharedInstance().setActive(true)

        guard currentAudioFile != nil, currentSong != nil else { return }

        if playerNode.isPlaying {
            await rescheduleCurrentTrackAfterRouteChange(shouldPlay: true)
        } else if frozenPositionWhilePaused != nil {
            await rescheduleCurrentTrackAfterRouteChange(shouldPlay: false)
        } else {
            ensureEngineRunning()
        }
    }

    /// Re-builds the scheduled buffer from the current timeline position so playback survives `AVAudioEngine` / route resets.
    private func rescheduleCurrentTrackAfterRouteChange(shouldPlay: Bool) async {
        guard let file = currentAudioFile else { return }
        let sr = file.processingFormat.sampleRate
        guard sr > 0 else { return }

        let rawT = currentTimelineSeconds()
        let clampedT: Double = if durationSeconds > 0 {
            min(max(0, rawT), durationSeconds)
        } else {
            max(0, rawT)
        }

        let length = file.length
        let frame = AVAudioFramePosition(clampedT * sr)
        let start = min(max(0, frame), max(length - 1, 0))
        let remaining = AVAudioFrameCount(max(0, length - start))
        guard remaining > 0 else { return }

        bumpPlaybackCompletionGeneration()
        playerNode.stop()
        frozenPositionWhilePaused = nil
        scheduledSegmentStartFrame = start
        positionSeconds = Double(start) / sr

        let completion = makeScheduleCompletionHandler()
        playerNode.scheduleSegment(file, startingFrame: start, frameCount: remaining, at: nil, completionHandler: completion)

        applyLoudnessGain()
        pushEqualiserToAudioUnit()

        if shouldPlay {
            do {
                try ensureEngineRunningThrowing()
                playerNode.play()
            } catch {
                #if DEBUG
                NSLog("UXMusic: route-change reschedule failed: %@", String(describing: error))
                #endif
            }
        } else {
            // Keep the engine stopped while intentionally paused — starting it here would make iOS
            // see an active audio session and potentially override playbackState=.paused with .playing.
            frozenPositionWhilePaused = Double(start) / sr
        }
        syncIsPlayingFromNode()
        updateNowPlayingCentre()
    }

    private func applyLoudnessGain() {
        let linear = LoudnessNormalisation.linearGain(
            songID: currentSong?.id, map: loudnessMap, target: targetLoudness, enabled: normaliseEnabled
        )
        // Mixer outputVolume only accepts 0...1; apply boosts in a dB-capable audio unit.
        normalisationUnit.bypass = false
        normalisationUnit.globalGain = max(-96, Float(20 * log10(linear)))
        engine.mainMixerNode.outputVolume = min(max(masterVolume, 0), 1)
    }

    func refreshVolumeForCurrentSong() {
        applyLoudnessGain()
    }

    // MARK: - Lock screen / Control Centre / background session

    private func installRemoteCommandHandlers() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatchToMainSync { [weak self] in
                guard let self else { return .commandFailed }
                self.activateSessionIfNeededSync()
                return self.remoteResumeAfterPlayCommand()
            }
        }

        c.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatchToMainSync { [weak self] in
                guard let self else { return .commandFailed }
                self.activateSessionIfNeededSync()
                guard self.currentSong != nil else { return .commandFailed }
                #if !os(tvOS)
                if let song = self.currentSong, song.isYouTube {
                    self.pauseYouTubeAndClearResumePending()
                    return .success
                }
                #endif
                self.frozenPositionWhilePaused = self.currentTimelineSeconds()
                self.playerNode.pause()
                self.engine.stop()
                self.syncIsPlayingFromNode()
                self.updateNowPlayingCentre()
                return .success
            }
        }

        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.dispatchToMainSync { [weak self] in
                guard let self else { return .commandFailed }
                self.activateSessionIfNeededSync()
                guard self.currentSong != nil else { return .commandFailed }
                #if !os(tvOS)
                if let song = self.currentSong, song.isYouTube {
                    self.toggleYouTubePlayPause()
                    return .success
                }
                #endif
                if self.playerNode.isPlaying {
                    self.frozenPositionWhilePaused = self.currentTimelineSeconds()
                    self.playerNode.pause()
                    self.engine.stop()
                    self.syncIsPlayingFromNode()
                    self.updateNowPlayingCentre()
                    return .success
                }
                if self.currentAudioFile != nil {
                    return self.remoteResumeAfterPlayCommand()
                }
                if let song = self.currentSong {
                    let generation = self.playGeneration.bump()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.loadAndPlay(song, generation: generation)
                    }
                }
                return .commandFailed
            }
        }

        c.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if Thread.isMainThread {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.next()
                }
                return .success
            }
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                defer { sem.signal() }
                guard let self else { return }
                await self.next()
            }
            sem.wait()
            return .success
        }

        c.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if Thread.isMainThread {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.previous()
                }
                return .success
            }
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor [weak self] in
                defer { sem.signal() }
                guard let self else { return }
                await self.previous()
            }
            sem.wait()
            return .success
        }

        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let ev = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self.dispatchToMainSync { [weak self] in
                guard let self else { return .commandFailed }
                self.activateSessionIfNeededSync()
                guard self.currentSong != nil else { return .commandFailed }
                self.seek(to: ev.positionTime, resumeAfterSeek: nil)
                return .success
            }
        }
    }

    /// The last payload pushed to the Now Playing centre (`nil` when nothing is published).
    private var lastNowPlayingPublication: NowPlayingPublication?

    /// - Parameter force: explicit state changes (play/pause/seek/song change/artwork) always
    ///   publish. The periodic callers (position timer, YouTube `.time`) pass `false` and only
    ///   publish when `NowPlayingPublication.shouldPublish` says something actually changed.
    private func updateNowPlayingCentre(force: Bool = true) {
        if !force, let song = currentSong {
            let candidate = makeNowPlayingPublication(for: song)
            guard NowPlayingPublication.shouldPublish(
                previous: lastNowPlayingPublication, next: candidate, now: candidate.publishedAt
            ) else { return }
        }
        // Do NOT call syncIsPlayingFromNode() here: callers are responsible for setting
        // isPlaying correctly before invoking this function. Re-reading playerNode.isPlaying
        // at this point risks overwriting the intended state with a transiently stale value
        // (e.g. immediately after playerNode.pause() before the engine pipeline drains).

        let c = MPRemoteCommandCenter.shared()
        let active = currentSong != nil
        let commandState = RemoteCommandEnablement.state(hasSong: active, isPlaying: isPlaying)
        c.playCommand.isEnabled = commandState.playEnabled
        c.pauseCommand.isEnabled = commandState.pauseEnabled
        c.togglePlayPauseCommand.isEnabled = commandState.toggleEnabled
        c.nextTrackCommand.isEnabled = active && queue.count > 1
        c.previousTrackCommand.isEnabled = active && queue.count > 1
        c.changePlaybackPositionCommand.isEnabled = active

        let nowPlaying = MPNowPlayingInfoCenter.default()

        guard let song = currentSong else {
            lastPublishedNowPlayingSongId = nil
            artworkLoadedForSongId = nil
            artworkInFlightForSongId = nil
            nowPlayingArtworkImage = nil
            nowPlaying.playbackState = .stopped
            nowPlaying.nowPlayingInfo = nil
            lastNowPlayingPublication = nil
            return
        }

        let songChanged = lastPublishedNowPlayingSongId != song.id
        if songChanged {
            lastPublishedNowPlayingSongId = song.id
            artworkLoadedForSongId = nil
            artworkInFlightForSongId = nil
            nowPlayingArtworkImage = nil
        }

        var info = nowPlaying.nowPlayingInfo ?? [:]
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
        // Keep rate and `playbackState` aligned with `isPlaying` (not a stale `playerNode.isPlaying` read).
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        if info[MPMediaItemPropertyArtwork] == nil,
           let img = nowPlayingArtworkImage,
           artworkLoadedForSongId == song.id {
            info[MPMediaItemPropertyArtwork] = makeMediaArtwork(from: img)
        }

        nowPlaying.nowPlayingInfo = info
        nowPlaying.playbackState = isPlaying ? .playing : .paused
        lastNowPlayingPublication = makeNowPlayingPublication(for: song)

        if loadArtworkImage != nil,
           artworkLoadedForSongId != song.id,
           artworkInFlightForSongId != song.id {
            ensureArtworkLoaded(for: song)
        }
    }

    private func makeNowPlayingPublication(for song: Song) -> NowPlayingPublication {
        let fromMetadata = song.duration > 0 ? song.duration : 0
        return NowPlayingPublication(
            songId: song.id,
            title: song.displayTitle,
            artist: song.displayArtist,
            album: song.displayAlbum,
            duration: max(max(durationSeconds, fromMetadata), 0.001),
            isPlaying: isPlaying,
            hasArtwork: nowPlayingArtworkImage != nil && artworkLoadedForSongId == song.id,
            skipEnabled: queue.count > 1,
            elapsed: max(0, positionSeconds),
            publishedAt: Date()
        )
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
                    self.engine.stop()
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
