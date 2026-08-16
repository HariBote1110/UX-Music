import Foundation

/// Grouping of songs by artist, analogous to `Album.fromSongs`. Keys on trimmed `albumArtist`,
/// falling back to trimmed `artist`, falling back to `"Unknown Artist"` when both are blank — the
/// same fallback chain the desktop library view uses so an artist bucket does not splinter just
/// because some tracks tag `albumartist` and others don't.
struct Artist: Equatable, Hashable, Identifiable, Sendable {
    /// Stable key: normalised artist name.
    var id: String { normalisedArtistName }
    var normalisedArtistName: String
    var songs: [Song]
    var albums: [Album]
    var artworkId: String

    var name: String { normalisedArtistName }
    var displayName: String { normalisedArtistName }

    static func fromSongs(_ songs: [Song]) -> [Artist] {
        var groups: [String: [Song]] = [:]
        for song in songs {
            let key = artistKey(for: song)
            groups[key, default: []].append(song)
        }

        var artists: [Artist] = []
        for (name, tracks) in groups {
            let sortedTracks = tracks.sorted(by: Song.libraryFlatDisplayOrderAscending)
            let albums = Album.fromSongs(tracks)
            let artwork = albums.first { !$0.artworkId.isEmpty }?.artworkId
                ?? sortedTracks.first { !$0.artworkId.isEmpty }?.artworkId
                ?? ""
            artists.append(
                Artist(
                    normalisedArtistName: name,
                    songs: sortedTracks,
                    albums: albums,
                    artworkId: artwork
                )
            )
        }
        artists.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return artists
    }

    /// `albumArtist` when present, else `artist`, else `"Unknown Artist"` (all trimmed).
    private static func artistKey(for song: Song) -> String {
        let albumArtist = song.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !albumArtist.isEmpty { return albumArtist }
        let trackArtist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trackArtist.isEmpty { return trackArtist }
        return "Unknown Artist"
    }
}
