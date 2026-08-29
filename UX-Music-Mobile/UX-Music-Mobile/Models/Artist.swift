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

    /// Variant of `fromSongs(_:)` that reuses an already-computed album grouping (typically
    /// `Album.fromSongs(songs)`, already sitting in a caller's cache for the Albums tab) instead of
    /// re-deriving album groups from scratch for every artist bucket.
    ///
    /// `precomputedAlbums` songs are assumed disc/track-sorted the way `Album.fromSongs` leaves
    /// them (see `Album.fromSongs`'s trailing sort pass). Filtering that sorted array down to one
    /// artist's subset preserves the order — the comparator only looks at discNumber/trackNumber/
    /// title, never at artist — so this produces identical `Artist.albums[*].songs` ordering to
    /// `fromSongs(songs)`, provided `precomputedAlbums == Album.fromSongs(songs)`.
    static func fromSongs(_ songs: [Song], precomputedAlbums: [Album]) -> [Artist] {
        var albumByTitle: [String: Album] = [:]
        albumByTitle.reserveCapacity(precomputedAlbums.count)
        for album in precomputedAlbums {
            albumByTitle[album.normalisedAlbumTitle] = album
        }

        var groups: [String: [Song]] = [:]
        for song in songs {
            groups[artistKey(for: song), default: []].append(song)
        }

        var artists: [Artist] = []
        for (name, tracks) in groups {
            let sortedTracks = tracks.sorted(by: Song.libraryFlatDisplayOrderAscending)

            var titlesForArtist: [String] = []
            var seenTitles = Set<String>()
            for song in tracks where seenTitles.insert(song.groupingAlbumTitle).inserted {
                titlesForArtist.append(song.groupingAlbumTitle)
            }

            var artistAlbums: [Album] = []
            for title in titlesForArtist {
                guard let fullAlbum = albumByTitle[title] else { continue }
                let songIdsForArtist = Set(tracks.filter { $0.groupingAlbumTitle == title }.map { $0.id })
                let orderedSongsForArtist = fullAlbum.songs.filter { songIdsForArtist.contains($0.id) }
                artistAlbums.append(
                    Album(
                        normalisedAlbumTitle: title,
                        artistName: representativeArtist(for: orderedSongsForArtist),
                        artworkId: orderedSongsForArtist.first { !$0.artworkId.isEmpty }?.artworkId ?? "",
                        songs: orderedSongsForArtist
                    )
                )
            }
            artistAlbums.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

            let artwork = artistAlbums.first { !$0.artworkId.isEmpty }?.artworkId
                ?? sortedTracks.first { !$0.artworkId.isEmpty }?.artworkId
                ?? ""
            artists.append(
                Artist(
                    normalisedArtistName: name,
                    songs: sortedTracks,
                    albums: artistAlbums,
                    artworkId: artwork
                )
            )
        }
        artists.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return artists
    }

    /// Same album-representative-artist heuristic `Album.fromSongs` uses, applied to an
    /// already-narrowed (single-artist) song subset.
    private static func representativeArtist(for songsInAlbum: [Song]) -> String {
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

    /// `albumArtist` when present, else `artist`, else `"Unknown Artist"` (all trimmed).
    private static func artistKey(for song: Song) -> String {
        let albumArtist = song.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !albumArtist.isEmpty { return albumArtist }
        let trackArtist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trackArtist.isEmpty { return trackArtist }
        return "Unknown Artist"
    }
}
