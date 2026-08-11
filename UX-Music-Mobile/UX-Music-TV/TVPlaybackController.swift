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
    func play(_ song: Song, queue: [Song]) async {
        connectionState = .buffering
        guard let currentIndex = queue.firstIndex(where: { $0.id == song.id }) else { return }

        do {
            let loudness = try await client.fetchLoudness()
            player.loudnessMap = loudness

            let idsToPrefetch = TVPrefetchPlanner.songIdsToPrefetch(
                queue: queue,
                currentIndex: currentIndex,
                prefetchCount: prefetchCount
            )
            let protectedIds = Set(idsToPrefetch)

            var cachedQueue = queue
            for id in idsToPrefetch {
                guard let idx = cachedQueue.firstIndex(where: { $0.id == id }) else { continue }
                let downloaded = try await cache.ensureCached(songId: id, protectedSongIds: protectedIds)
                cachedQueue[idx].path = downloaded.fileURL.path
            }

            guard let activeIdx = cachedQueue.firstIndex(where: { $0.id == song.id }) else { return }
            let active = cachedQueue[activeIdx]
            await cache.pinCurrentlyPlaying(songId: active.id)
            await player.play(active, newQueue: cachedQueue)
            connectionState = .ready
        } catch {
            connectionState = .unreachable(message: error.localizedDescription)
        }
    }
}
