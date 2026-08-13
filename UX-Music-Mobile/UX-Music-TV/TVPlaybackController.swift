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

    private let client: RemoteAPIClient
    private let cache: TVPlaybackCacheStore
    private let player: MusicPlayerService
    private let prefetchCount: Int

    init(
        client: RemoteAPIClient,
        player: MusicPlayerService,
        cache: TVPlaybackCacheStore? = nil,
        prefetchCount: Int = 2
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
    }

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
        connectionState = .buffering
        guard let currentIndex = queue.firstIndex(where: { $0.id == song.id }) else { return }

        let idsToPrefetch = TVPrefetchPlanner.songIdsToPrefetch(
            queue: queue,
            currentIndex: currentIndex,
            prefetchCount: prefetchCount
        )
        let protectedIds = Set(idsToPrefetch)
        let trailingIds = idsToPrefetch.filter { $0 != song.id }

        do {
            async let loudnessTask = client.fetchLoudness()
            let downloaded = try await cache.ensureCached(songId: song.id, protectedSongIds: protectedIds)

            var active = song
            active.path = downloaded.fileURL.path
            var cachedQueue = queue
            if let idx = cachedQueue.firstIndex(where: { $0.id == song.id }) {
                cachedQueue[idx].path = downloaded.fileURL.path
            }

            player.loudnessMap = try await loudnessTask
            await cache.pinCurrentlyPlaying(songId: active.id)
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
}
