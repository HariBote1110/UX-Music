import Foundation

/// Lightweight playlist metadata transferred to the Apple Watch from the paired iPhone, and the
/// pure logic for turning a playlist into a playback queue.
///
/// Mirrors the shape of the iOS `Playlist` model (`Models/Playlist.swift`: `id`/`name`/`songIds`,
/// an ordered list of `Song.id` values) but, like `WatchTransferMeta` for songs, is kept as its own
/// small `Codable` type rather than reusing `Playlist` directly — the Watch has no use for
/// `createdAt`/`updatedAt`, and keeping the transferred payload minimal matters on watchOS's
/// constrained WatchConnectivity transport (see `WatchTransferMeta`'s doc comment for the same
/// reasoning applied to songs).
///
/// **Transport**: see `WatchConnectivityReceiver`'s doc comment for exactly how this is received
/// (a `transferFile` tagged `kind: "playlists"`, mirroring the existing artwork transfer's tagging
/// pattern). The iOS side sends it from `WatchTransferBridge.sendPlaylists(_:)` whenever the
/// playlist store changes and on session activation.
struct WatchPlaylistMeta: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// Ordered `WatchTransferMeta.id` values — the same song ids used for `WatchLocalLibrary.songs`
    /// — so a playlist can be resolved against whatever songs have actually been transferred to the
    /// Watch, in `WatchPlaylistQueueBuilder`.
    var songIds: [String]

    var displayName: String { name.isEmpty ? String(localized: "Untitled Playlist") : name }
}

/// Pure logic for resolving a `WatchPlaylistMeta` (a list of song ids) against the Watch's actually
/// -received song library, and building a `(song, queue)` pair suitable for
/// `WatchAudioPlayerService.play(_:queue:)` — the same shape `WatchSongRow.body` already passes when
/// starting playback from a list or album. No `WatchAudioPlayerService`/SwiftUI dependency, so this
/// is unit-testable without a running app.
enum WatchPlaylistQueueBuilder {
    /// Resolves `playlist.songIds` against `librarySongs`, preserving the playlist's own order and
    /// silently dropping any id the Watch has not received a song for (the same "graceful skip"
    /// behaviour `WatchResumeLogic` uses for a resume queue with missing songs).
    static func resolvedSongs(for playlist: WatchPlaylistMeta, librarySongs: [WatchTransferMeta]) -> [WatchTransferMeta] {
        let byId = Dictionary(uniqueKeysWithValues: librarySongs.map { ($0.id, $0) })
        return playlist.songIds.compactMap { byId[$0] }
    }

    /// Builds the `(song, queue)` pair to hand to `WatchAudioPlayerService.play(_:queue:)` when the
    /// user taps a song at `songId` within `playlist` — the queue is the playlist's *resolved* songs
    /// (missing ones dropped, see `resolvedSongs`), positioned so playback starts at `songId`.
    /// `nil` if `songId` is not (or is no longer) part of the resolved queue.
    static func queue(
        for playlist: WatchPlaylistMeta,
        startingAt songId: String,
        librarySongs: [WatchTransferMeta]
    ) -> (song: WatchTransferMeta, queue: [WatchTransferMeta])? {
        let resolved = resolvedSongs(for: playlist, librarySongs: librarySongs)
        guard let song = resolved.first(where: { $0.id == songId }) else { return nil }
        return (song, resolved)
    }
}
