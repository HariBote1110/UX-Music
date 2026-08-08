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

/// Geometry of the connector line drawn in place of (or under) a song row's artwork for a run of
/// consecutive same-album rows. Kept pure and separate from the SwiftUI `Canvas` so the one property
/// that actually matters — the line is *continuous* once rows are stacked with no gap between them —
/// is unit-testable.
///
/// Coordinates are row-local: `y == 0` is the row's top edge, `y == rowHeight` its bottom edge.
enum AlbumGroupConnector {
    /// A vertical run of the connector line within one row.
    struct Segment: Equatable {
        let fromY: CGFloat
        let toY: CGFloat
    }

    /// The vertical line this row contributes, or `nil` when the row draws no connector at all.
    ///
    /// `.first` still shows its artwork, so its line is only the stub between the artwork's bottom
    /// edge and the row's bottom edge — that stub is what closes the gap to the next row's line.
    static func verticalSegment(
        for position: AlbumGroupPosition,
        rowHeight: CGFloat,
        artworkSize: CGFloat
    ) -> Segment? {
        switch position {
        case .single:
            return nil
        case .first:
            return Segment(fromY: (rowHeight + artworkSize) / 2, toY: rowHeight)
        case .middle:
            return Segment(fromY: 0, toY: rowHeight)
        case .last:
            return Segment(fromY: 0, toY: rowHeight / 2)
        }
    }

    /// Whether the row closes the run with a horizontal elbow running right from the line's end —
    /// the `└` the desktop draws under the group's first-row artwork.
    static func hasElbow(for position: AlbumGroupPosition) -> Bool {
        position == .last
    }
}
