import Foundation

/// Pure, testable library search matcher. Matches a `Song` against a free-text query across title,
/// artist, album, and album artist, case- and diacritic-insensitive. A blank query matches
/// everything (used by screens that show the full list until the user types).
enum SongSearchFilter {
    /// `true` when every whitespace-separated token in `query` matches somewhere in `song`'s
    /// searchable fields (AND across tokens, OR across fields per token).
    static func matches(_ song: Song, query: String) -> Bool {
        let tokens = searchTokens(for: query)
        guard !tokens.isEmpty else { return true }
        let haystacks = [song.title, song.artist, song.album, song.albumArtist]
        return tokens.allSatisfy { token in
            haystacks.contains { haystack in
                haystack.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// Convenience: filters a list, preserving order.
    static func filter(_ songs: [Song], query: String) -> [Song] {
        let tokens = searchTokens(for: query)
        guard !tokens.isEmpty else { return songs }
        return songs.filter { matches($0, query: query) }
    }

    private static func searchTokens(for query: String) -> [String] {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }
}
