import Foundation

/// Grouping of songs by album, aligned with desktop `groupLibraryByAlbum` in `ui-manager.js`:
/// one group per normalised album title; compilations with empty `albumartist` no longer split per track artist.
struct Album: Equatable, Hashable, Identifiable, Sendable {
    /// Stable key: normalised album title (matches desktop `albumKey`).
    var id: String { normalisedAlbumTitle }
    /// Canonical album title for this group (`Unknown Album` when tags are empty).
    var normalisedAlbumTitle: String
    var artistName: String
    var artworkId: String
    var songs: [Song]

    var name: String { normalisedAlbumTitle }

    var displayName: String { normalisedAlbumTitle }
    var displayArtist: String { artistName.isEmpty ? "Unknown Artist" : artistName }

    static func fromSongs(_ songs: [Song]) -> [Album] {
        var groups: [String: [Song]] = [:]
        for song in songs {
            let key = song.groupingAlbumTitle
            groups[key, default: []].append(song)
        }

        func representativeArtist(for songsInAlbum: [Song]) -> String {
            var albumArtists = Set<String>()
            var trackArtists = Set<String>()
            for song in songsInAlbum {
                let aa = song.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
                if !aa.isEmpty {
                    albumArtists.insert(aa)
                }
                let ar = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                trackArtists.insert(ar.isEmpty ? "Unknown Artist" : ar)
            }
            if albumArtists.count == 1 {
                return albumArtists.first!
            }
            if albumArtists.count > 1 {
                return "Various Artists"
            }
            if trackArtists.count == 1 {
                return trackArtists.first!
            }
            if trackArtists.count > 1 {
                return "Various Artists"
            }
            return "Unknown Artist"
        }

        func firstArtworkId(in songsInAlbum: [Song]) -> String {
            songsInAlbum.first { !$0.artworkId.isEmpty }?.artworkId ?? ""
        }

        var albums: [Album] = []
        for (title, tracks) in groups {
            albums.append(
                Album(
                    normalisedAlbumTitle: title,
                    artistName: representativeArtist(for: tracks),
                    artworkId: firstArtworkId(in: tracks),
                    songs: tracks
                )
            )
        }
        albums.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        for i in albums.indices {
            albums[i].songs.sort {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
            }
        }
        return albums
    }
}
