import Foundation

/// Resolves server-generated `SituationPlaylist` rows (see `RemoteAPIClient.SituationPlaylist`)
/// against the local Library so the "For You" segment can render sections without duplicating the
/// songId→Song lookup in every caller. Pure and SwiftUI-free so the resolution rule is
/// unit-testable independent of how the View agent lays out the sections.
enum SituationPlaylistResolver {
    struct Section: Equatable, Sendable {
        var name: String
        var songs: [Song]
    }

    /// Resolves every `songIds` entry against `library`, preserving both playlist order and each
    /// playlist's internal song order. Songs missing from `library` (not downloaded, or the desktop
    /// removed them) are silently dropped rather than erroring — matches the "seamless, DL-first"
    /// UX Sync philosophy where an unavailable track just doesn't show up. Playlists that resolve to
    /// zero songs are omitted entirely so a "For You" section never renders empty.
    static func resolve(_ playlists: [SituationPlaylist], library: [Song]) -> [Section] {
        var byId: [String: Song] = [:]
        for song in library { byId[song.id] = song }
        return playlists.compactMap { playlist in
            let songs = playlist.songIds.compactMap { byId[$0] }
            guard !songs.isEmpty else { return nil }
            return Section(name: playlist.name, songs: songs)
        }
    }
}
