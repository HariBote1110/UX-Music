import Combine
import Foundation

/// Wires Phase 1-4's prefetch → cache → `MusicPlayerService` pipeline together
/// (`markdown/appletv-servermode-plan.md` §1-4). `MusicPlayerService` itself is unmodified and
/// shared with iOS/watchOS — it already reads `Song.path` as a local file path and applies the
/// same EQ/LUFS chain regardless of platform, so this controller's only job is to make sure a
/// cached local file exists at that path (and that `loudnessMap` is populated) before handing the
/// song to `play(_:newQueue:)`.
@MainActor
final class TVPlaybackController: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case buffering
        case ready
        case unreachable(message: String)
    }

    @Published private(set) var connectionState: ConnectionState = .idle
    /// Task A stream-first playback state (`progress/tvos-playback.md`). `.idle` whenever the
    /// current track played from cache (the unchanged fast path) — only a cache MISS drives this
    /// through `.loading` → `.streaming` → `.finished`/`.failed`. The browse/Now Playing UI binds
    /// its loading spinner to `TVSongStreamPlaybackReducer.isLoading(streamState)`.
    @Published private(set) var streamState: TVSongStreamPlaybackState = .idle

    private let client: RemoteAPIClient
    private let cache: TVPlaybackCacheStore
    private let player: MusicPlayerService
    private let prefetchCount: Int
    private let streamController: TVSongStreamController
    /// Set by `play(_:queue:)` right before starting a stream so `advanceAfterStreamEnd` knows
    /// which queue to advance from — `TVSongStreamController` itself is queue-agnostic.
    private var streamingQueue: [Song] = []
    private var streamingSongIndex: Int = 0
    /// Polls `TVSongStreamController.elapsedSeconds` into `player.updateExternalPlaybackProgress`
    /// while streaming owns Now Playing — there is no local `AVAudioEngine` timeline to derive
    /// progress from during a stream (see `MusicPlayerService`'s "External playback bridging"
    /// section). Cancelled whenever streaming stops/finishes/fails.
    private var progressMirrorTask: Task<Void, Never>?
    /// Bumped at the very top of every `play(_:queue:)` call, BEFORE any `await`. Each call
    /// captures its own value (`myToken`) and re-checks `myToken == playToken` after every
    /// suspension point before doing anything with externally-visible effect (starting a stream,
    /// calling `player.play`, mutating `streamingQueue`/`connectionState`). This is what makes
    /// concurrent/rapid `play()` calls self-superseding rather than racing: `play()` is `async`
    /// and has several `await`s (cache lookup, loudness fetch, download), and nothing previously
    /// prevented two overlapping calls (e.g. a user tap racing `advanceAfterStreamEnd`'s
    /// fire-and-forget `Task`) from interleaving their side effects — the exact "startup-phase
    /// switching" and "rapid hop" symptoms in `progress/tvos-playback-concurrency.md`. A
    /// superseded call bails out silently the moment it notices; only the LAST call to reach a
    /// checkpoint is allowed through it, so at most one `play()` invocation ever ends up actually
    /// starting audio at a time — enforced by construction, not by hoping callers serialise
    /// themselves.
    private var playToken: Int = 0

    init(
        client: RemoteAPIClient,
        player: MusicPlayerService,
        cache: TVPlaybackCacheStore? = nil,
        prefetchCount: Int = 2,
        streamPlayerFactory: @escaping () -> TVRelayStreamPlayer = { TVRelayStreamPlayer() }
    ) {
        self.client = client
        self.player = player
        self.prefetchCount = prefetchCount
        if let cache {
            self.cache = cache
        } else {
            self.cache = TVPlaybackCacheStore(
                directory: TVPlaybackCacheStore.defaultDirectory(),
                downloader: { songId, destination in
                    try await client.downloadFile(songId: songId, to: destination, progress: { _, _ in })
                }
            )
        }
        self.streamController = TVSongStreamController(client: client, streamPlayerFactory: streamPlayerFactory)
        streamController.$state.receive(on: DispatchQueue.main).sink { [weak self] in self?.streamState = $0 }
            .store(in: &cancellables)
        streamController.onStreamEnded = { [weak self] didFinishNaturally in
            Task { @MainActor [weak self] in
                self?.stopProgressMirror()
                self?.player.endExternalPlayback()
                self?.advanceAfterStreamEnd(didFinishNaturally: didFinishNaturally)
            }
        }
        // Now Playing transport bridge (`progress/tvos-playback.md` "Now Playing 統合" 追記):
        // routes `MusicPlayerService`'s transport calls back to the stream while
        // `player.isExternallyDriven` is true — see `MusicPlayerService`'s "External playback
        // bridging" section for why this exists (the streamed song has no local file for the
        // service's own engine to load).
        player.externalPlaybackCommandHandler = { [weak self] command in
            guard let self else { return }
            switch command {
            case .togglePlayPause:
                self.streamController.togglePlayPause()
                self.player.setExternalPlaybackIsPlaying(!self.streamController.isPaused)
            case .next:
                self.advanceStreamingQueue(by: 1)
            case .previous:
                self.advanceStreamingQueue(by: -1)
            case .stop:
                self.stopProgressMirror()
                self.streamController.stop()
            }
        }
    }

    private func stopProgressMirror() {
        progressMirrorTask?.cancel()
        progressMirrorTask = nil
    }

    /// Explicit skip forward/back (Now Playing transport buttons) while streaming owns playback —
    /// mirrors `MusicPlayerService.next()`/`previous()`'s "always wrap" shape but, like
    /// `advanceAfterStreamEnd`, must drive the queue itself since the streamed song was never
    /// handed to `MusicPlayerService`'s own queue.
    private func advanceStreamingQueue(by delta: Int) {
        guard !streamingQueue.isEmpty else { return }
        let count = streamingQueue.count
        let nextIndex = ((streamingSongIndex + delta) % count + count) % count
        let nextSong = streamingQueue[nextIndex]
        let queue = streamingQueue
        Task { [weak self] in
            await self?.play(nextSong, queue: queue)
        }
    }

    private var cancellables = Set<AnyCancellable>()

    /// Starts playback of `song` from `queue` (album/playlist tap → play-from-selection, per
    /// §1-4's queue rule), prefetching `song` plus the next `prefetchCount` queue entries.
    ///
    /// Ordering matters here (see `progress/tvos-playback.md` "再生開始レイテンシ" 追記): only the
    /// CURRENT track is awaited before handing off to `MusicPlayerService.play`. The loudness fetch
    /// runs concurrently with that download (`async let`), and every other queue entry's prefetch is
    /// fired off in a detached, non-awaited `Task` AFTER audio has started — it must never sit on the
    /// critical path between a tap and first sound.
    func play(_ song: Song, queue: [Song]) async {
        #if DEBUG
        let tapStart = DispatchTime.now()
        #endif
        playToken += 1
        let myToken = playToken
        streamController.stop() // any previous stream-first playback is no longer relevant
        stopProgressMirror()
        connectionState = .buffering
        guard let currentIndex = queue.firstIndex(where: { $0.id == song.id }) else { return }

        let idsToPrefetch = TVPrefetchPlanner.songIdsToPrefetch(
            queue: queue,
            currentIndex: currentIndex,
            prefetchCount: prefetchCount
        )
        let protectedIds = Set(idsToPrefetch)
        let trailingIds = idsToPrefetch.filter { $0 != song.id }

        // Task A: a cache hit takes the unchanged fast path below; a miss starts streaming
        // IMMEDIATELY (before the loudness fetch even resolves) so first audio never waits on the
        // full-file download. This check is synchronous disk I/O only — no network round-trip.
        let cacheHit = await cache.isCached(songId: song.id)
        guard myToken == playToken else { return } // superseded by a newer play() while awaiting the cache check
        if TVSongPlaybackPlan.shouldStream(cacheHit: cacheHit) {
            streamingQueue = queue
            streamingSongIndex = currentIndex
            let loudnessMap = (try? await client.fetchLoudness()) ?? player.loudnessMap
            guard myToken == playToken else { return } // superseded while awaiting loudness
            player.loudnessMap = loudnessMap
            let gain = Self.linearLoudnessGain(
                lufs: loudnessMap[song.id],
                targetLoudness: player.targetLoudness,
                normaliseEnabled: player.normaliseEnabled
            )
            streamController.start(songId: song.id, outputGain: gain)
            connectionState = .ready // "ready" here means "stream request in flight"; streamState carries the real loading UI

            // Now Playing shows title/artwork/progress from the FIRST streamed frame onward (not
            // just once cached), per the brief: `TVNowPlayingView` reads exclusively from `player`,
            // so mirror the song in immediately rather than waiting for `didStartRendering`.
            player.beginExternalPlayback(song: song, durationSeconds: song.duration)
            progressMirrorTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.player.updateExternalPlaybackProgress(seconds: self.streamController.elapsedSeconds)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            // Fire-and-forget: download the ORIGINAL file into the cache in the background so the
            // NEXT play (or a repeat) uses the fully-EQ'd cached path. Deliberately does not
            // hot-swap the currently-streaming audio mid-song (documented future option in
            // `progress/tvos-playback.md`).
            let cacheStore = cache
            Task.detached(priority: .utility) {
                _ = try? await cacheStore.ensureCached(songId: song.id, protectedSongIds: protectedIds)
                for id in trailingIds {
                    _ = try? await cacheStore.ensureCached(songId: id, protectedSongIds: protectedIds)
                }
            }
            return
        }

        do {
            stopProgressMirror()
            async let loudnessTask = client.fetchLoudness()
            let downloaded = try await cache.ensureCached(songId: song.id, protectedSongIds: protectedIds)
            guard myToken == playToken else { return } // superseded while awaiting the download

            var active = song
            active.path = downloaded.fileURL.path
            var cachedQueue = queue
            if let idx = cachedQueue.firstIndex(where: { $0.id == song.id }) {
                cachedQueue[idx].path = downloaded.fileURL.path
            }

            player.loudnessMap = try await loudnessTask
            guard myToken == playToken else { return } // superseded while awaiting loudness
            await cache.pinCurrentlyPlaying(songId: active.id)
            guard myToken == playToken else { return } // superseded while pinning
            await player.play(active, newQueue: cachedQueue)
            connectionState = .ready
            #if DEBUG
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - tapStart.uptimeNanoseconds) / 1_000_000
            NSLog("[TVPlay] tap→firstAudio: %.0fms", elapsedMs)
            #endif

            // Fire-and-forget: the remaining prefetch window downloads in the background and must
            // never block (or be blocked by) the audio that is already playing.
            let cacheStore = cache
            Task.detached(priority: .utility) {
                for id in trailingIds {
                    _ = try? await cacheStore.ensureCached(songId: id, protectedSongIds: protectedIds)
                }
            }
        } catch {
            connectionState = .unreachable(message: error.localizedDescription)
        }
    }

    /// Track-end/failure handoff from the streaming path: `MusicPlayerService.advanceAfterEnd()`
    /// handles queue advance for the cached path internally (it owns the queue once
    /// `player.play` is called), but the stream-first path never hands the song to
    /// `MusicPlayerService` at all, so this controller must advance the queue itself. Mirrors
    /// `PlaybackQueueNavigation.autoAdvance`'s "just go to the next index" shape, kept minimal
    /// since Task A explicitly scopes out repeat-mode handling for the streaming path (falls back
    /// to the cache-backed path on the next queue entry via a fresh `play(_:queue:)`, which
    /// re-evaluates cache-hit/miss and repeat naturally on THAT call).
    private func advanceAfterStreamEnd(didFinishNaturally: Bool) {
        guard didFinishNaturally else { return } // a failed stream does not auto-advance
        let nextIndex = streamingSongIndex + 1
        guard nextIndex < streamingQueue.count else { return }
        let nextSong = streamingQueue[nextIndex]
        let queue = streamingQueue
        Task { [weak self] in
            await self?.play(nextSong, queue: queue)
        }
    }

    /// Linear LUFS gain — identical formula/clamp to `MusicPlayerService.applyLoudnessGain()` —
    /// computed here (rather than exposed from `MusicPlayerService`, which keeps its engine/EQ
    /// fully private) so `TVSongStreamController`'s standalone engine can apply the same loudness
    /// normalisation as the cached path. See `TVRelayStreamPlayer`'s "EQ routing decision" doc
    /// comment for why only gain (not the 10-band EQ curve) is replicated here.
    nonisolated static func linearLoudnessGain(lufs: Double?, targetLoudness: Double, normaliseEnabled: Bool) -> Float {
        guard normaliseEnabled, let lufs else { return 1 }
        let gainDb = targetLoudness - lufs
        let lin = pow(10, gainDb / 20)
        return min(max(Float(lin), 0), 4)
    }
}
