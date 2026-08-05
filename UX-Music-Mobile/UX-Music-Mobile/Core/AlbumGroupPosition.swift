import Foundation

/// Where a song row sits within a run of consecutive same-album rows, for the "artwork only on the
/// group's first row, connector line down to the last row" rendering the desktop uses (see
/// `src/renderer/js/ui/element-factory.ts:62`, `createSongItem`'s `groupAlbumArt` handling). Pure
/// and free of SwiftUI so the grouping rule is unit-testable independent of how the View agent
/// chooses to draw it.
enum AlbumGroupPosition: Equatable, Sendable {
    /// The only row for its album in this run (no neighbours share the same album here).
    case single
    /// First row of a multi-row run.
    case first
    /// Interior row of a multi-row run (neither first nor last).
    case middle
    /// Last row of a multi-row run.
    case last
}

enum AlbumGrouping {
    /// Groups `songs` (already in display order) into consecutive runs keyed by
    /// `Song.groupingAlbumTitle`, returning one `AlbumGroupPosition` per input song in the same
    /// order. Non-adjacent repeats of the same album (e.g. a shuffled or manually-edited queue)
    /// form separate runs rather than merging — only *consecutive* rows sharing an album collapse.
    static func positions(for songs: [Song]) -> [AlbumGroupPosition] {
        var result: [AlbumGroupPosition] = []
        result.reserveCapacity(songs.count)
        var i = 0
        while i < songs.count {
            var j = i
            while j + 1 < songs.count, songs[j + 1].groupingAlbumTitle == songs[i].groupingAlbumTitle {
                j += 1
            }
            if j == i {
                result.append(.single)
            } else {
                for k in i ... j {
                    if k == i {
                        result.append(.first)
                    } else if k == j {
                        result.append(.last)
                    } else {
                        result.append(.middle)
                    }
                }
            }
            i = j + 1
        }
        return result
    }
}
