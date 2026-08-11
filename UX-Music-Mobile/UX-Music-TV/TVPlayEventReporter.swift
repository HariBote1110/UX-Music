import Foundation
import os.log

/// Reports a track's natural completion to the paired host via `POST /v1/remote/play-event`
/// (`markdown/appletv-servermode-plan.md` §3-2). Fire-and-forget from the caller's point of view:
/// `report(song:finishedAt:)` never throws and never blocks playback — it fires a detached `Task`,
/// tries once, retries once more on failure, and only logs (never surfaces to the UI) if both
/// attempts fail. The host endpoint is idempotent by design (`progress/remote-play-event.md`), so
/// a retry after a transient failure cannot double-count a play.
struct TVPlayEventReporter {
    private let client: RemoteAPIClient
    private let logger = Logger(subsystem: "com.uxlabs.uxMusicMobile.tv", category: "play-event")

    init(client: RemoteAPIClient) {
        self.client = client
    }

    /// Call from `MusicPlayerService.onTrackNaturallyFinished`. Applies
    /// `TVPlayEventPolicy.shouldReport` before doing any networking.
    func report(song: Song, finishedAt: Date = Date()) {
        guard TVPlayEventPolicy.shouldReport(song: song) else { return }
        let playedAt = TVPlayEventPolicy.rfc3339(finishedAt)
        let trackId = song.id
        let durationPlayedSec = song.duration > 0 ? song.duration : nil
        Task.detached { [client, logger] in
            do {
                try await client.postPlayEvent(trackId: trackId, playedAt: playedAt, durationPlayedSec: durationPlayedSec)
            } catch {
                do {
                    try await client.postPlayEvent(trackId: trackId, playedAt: playedAt, durationPlayedSec: durationPlayedSec)
                } catch {
                    logger.error("play-event report failed after retry for track \(trackId, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
