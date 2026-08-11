import Foundation

/// Pure decision logic for the TV play-event reporter (`markdown/appletv-servermode-plan.md`
/// §3-2): given a song that `MusicPlayerService.onTrackNaturallyFinished` reported, decide whether
/// it is worth telling the host about at all, and format the RFC3339 timestamp the host's
/// `POST /v1/remote/play-event` requires (`progress/remote-play-event.md`). No networking, no
/// dates read from `Date()` internally (the caller supplies `now`) — fully deterministic and
/// XCTest-able.
enum TVPlayEventPolicy {
    /// `onTrackNaturallyFinished` only fires on a genuine natural end-of-track, so in the normal
    /// case this is always `true` — the guard exists for degenerate metadata (empty id, or a
    /// non-positive duration, which would mean the "song" never really played) rather than for
    /// distinguishing skips from completions (that distinction is already made by which
    /// `MusicPlayerService` callback fired).
    static func shouldReport(song: Song) -> Bool {
        !song.id.isEmpty && song.duration > 0
    }

    /// Formats `date` as RFC3339 in UTC with fractional seconds, matching what
    /// `progress/remote-play-event.md` documents the host expects (`playedAt` must parse as
    /// RFC3339; "must always be sent in UTC").
    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
