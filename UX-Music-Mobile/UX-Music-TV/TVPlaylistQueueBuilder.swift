import Foundation

/// Pure helper that turns a `RemoteDesktopPlaylist` (only `songIds`, no full `Song` values) into
/// an ordered `[Song]` queue for tap-to-play, mirroring the album shelf's play-from-selection rule
/// (`markdown/appletv-servermode-plan.md` §1-4). Wiring this up was the "known gap" recorded in
/// `progress/tvos-nowplaying.md` — the album shelf had this from the start, the playlist shelf did
/// not.
///
/// No network/store access here: `allSongs` is whatever `TVBrowseModel` already fetched, so the
/// mapping is a pure, synchronous, unit-testable lookup.
enum TVPlaylistQueueBuilder {
    /// Resolves `playlist.songIds` against `allSongs`, preserving playlist order. Song ids that
    /// are missing from `allSongs` (e.g. `pathsNotInLibrary`) are silently skipped rather than
    /// producing a gap/crash — the desktop's own playlist views apply the same "skip missing"
    /// rule.
    static func songs(for playlist: RemoteDesktopPlaylist, allSongs: [Song]) -> [Song] {
        guard !allSongs.isEmpty, !playlist.songIds.isEmpty else { return [] }
        var byId: [String: Song] = [:]
        byId.reserveCapacity(allSongs.count)
        for song in allSongs {
            byId[song.id] = song
        }
        return playlist.songIds.compactMap { byId[$0] }
    }
}
