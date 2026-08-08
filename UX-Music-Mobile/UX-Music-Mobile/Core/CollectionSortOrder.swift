import Foundation

/// User-selectable sort order for the local Library album grid. `.name` is the existing default
/// (`Album.fromSongs` already sorts alphabetically by `displayName`); every other case falls back
/// to that same comparator on ties so the sort stays stable rather than reordering equally-named/
/// equally-sized albums at random.
enum AlbumSortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case artist
    case songCount

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: return "アルバム名順"
        case .artist: return "アーティスト名順"
        case .songCount: return "曲数順"
        }
    }

    /// Sorts `albums` by this order, falling back to alphabetical album name on ties.
    func sorted(_ albums: [Album]) -> [Album] {
        albums.sorted(by: comparator)
    }

    private var comparator: (Album, Album) -> Bool {
        switch self {
        case .name:
            return Self.nameAscending
        case .artist:
            return { a, b in
                let c = a.displayArtist.localizedCaseInsensitiveCompare(b.displayArtist)
                if c != .orderedSame { return c == .orderedAscending }
                return Self.nameAscending(a, b)
            }
        case .songCount:
            return { a, b in
                if a.songs.count != b.songs.count { return a.songs.count > b.songs.count }
                return Self.nameAscending(a, b)
            }
        }
    }

    private static func nameAscending(_ a: Album, _ b: Album) -> Bool {
        a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }
}

/// User-selectable sort order for the local Library artist list. `.name` is the existing default
/// (`Artist.fromSongs` already sorts alphabetically by `displayName`); `.songCount` falls back to
/// that same comparator on ties so the sort stays stable rather than reordering equally-sized
/// artists at random.
enum ArtistSortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case songCount

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: return "名前順"
        case .songCount: return "曲数順"
        }
    }

    /// Sorts `artists` by this order, falling back to alphabetical name on ties.
    func sorted(_ artists: [Artist]) -> [Artist] {
        artists.sorted(by: comparator)
    }

    private var comparator: (Artist, Artist) -> Bool {
        switch self {
        case .name:
            return Self.nameAscending
        case .songCount:
            return { a, b in
                if a.songs.count != b.songs.count { return a.songs.count > b.songs.count }
                return Self.nameAscending(a, b)
            }
        }
    }

    private static func nameAscending(_ a: Artist, _ b: Artist) -> Bool {
        a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }
}
