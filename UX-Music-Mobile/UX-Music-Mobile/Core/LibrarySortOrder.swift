import Foundation

/// User-selectable sort order for the local Library song list. `.album` is the existing default
/// (`Song.libraryFlatDisplayOrderAscending`); every other case falls back to that same comparator
/// on ties so the sort stays stable rather than reordering equally-titled/artist'd tracks at random.
enum LibrarySortOrder: String, CaseIterable, Identifiable, Codable, Sendable {
    case album
    case title
    case artist
    case duration

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .album: return String(localized: "By Album")
        case .title: return String(localized: "By Title")
        case .artist: return String(localized: "By Artist")
        case .duration: return String(localized: "By Duration")
        }
    }

    /// Sorts `songs` by this order, falling back to `Song.libraryFlatDisplayOrderAscending` on ties.
    func sorted(_ songs: [Song]) -> [Song] {
        songs.sorted(by: comparator)
    }

    private var comparator: (Song, Song) -> Bool {
        switch self {
        case .album:
            return Song.libraryFlatDisplayOrderAscending
        case .title:
            return { a, b in
                let c = a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle)
                if c != .orderedSame { return c == .orderedAscending }
                return Song.libraryFlatDisplayOrderAscending(a, b)
            }
        case .artist:
            return { a, b in
                let c = a.displayArtist.localizedCaseInsensitiveCompare(b.displayArtist)
                if c != .orderedSame { return c == .orderedAscending }
                return Song.libraryFlatDisplayOrderAscending(a, b)
            }
        case .duration:
            return { a, b in
                if a.duration != b.duration { return a.duration < b.duration }
                return Song.libraryFlatDisplayOrderAscending(a, b)
            }
        }
    }
}
