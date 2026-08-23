import SwiftUI

/// Shared grid column spec for the Library screens' Albums/Artists/Playlists grids.
///
/// Every one of those grids used to hard-code `[GridItem(.flexible()), GridItem(.flexible())]` —
/// always exactly two columns, which is right for an iPhone but leaves an iPad's width mostly
/// empty (or stretches two tiles absurdly wide). `.adaptive` instead asks SwiftUI to fit as many
/// `minimumTileWidth`-or-wider columns as the container allows (growing them up to
/// `maximumTileWidth` to fill any remainder), so an iPhone portrait width still settles on 2
/// columns and an iPad settles on 4-6 — see `columnCount(for:)` below for the pure version of that
/// same maths, used in tests to pin the tuning down without a live layout pass.
enum AdaptiveGridColumns {
    /// Below this, a tile starts looking cramped for artwork + two lines of text.
    static let minimumTileWidth: CGFloat = 160
    /// Ceiling so very wide windows (iPad landscape, Stage Manager) don't stretch tiles past a
    /// sensible artwork size — kept close to `minimumTileWidth` on purpose.
    static let maximumTileWidth: CGFloat = 220

    /// `.adaptive` column spec using the tuned width range above. Callers keep supplying their own
    /// `LazyVGrid(spacing:)` (row *and* inter-column spacing, since these `GridItem`s don't
    /// override their own `spacing`) so existing per-screen gaps are unaffected.
    static func columns() -> [GridItem] {
        [GridItem(.adaptive(minimum: minimumTileWidth, maximum: maximumTileWidth))]
    }

    /// Pure column-count maths mirroring `.adaptive`'s "fit as many `minimum`-wide columns (with
    /// `spacing` between them) as possible" rule, given a container `availableWidth`. Always at
    /// least 1. This exists so the `minimumTileWidth`/`maximumTileWidth` tuning can be verified
    /// against real device widths without needing a hosted view/live layout pass.
    static func columnCount(
        for availableWidth: CGFloat,
        minimum: CGFloat = minimumTileWidth,
        spacing: CGFloat = 16
    ) -> Int {
        guard availableWidth > 0, minimum > 0 else { return 1 }
        // n columns of `minimum` width need: n * minimum + (n - 1) * spacing <= availableWidth
        // <=> n <= (availableWidth + spacing) / (minimum + spacing)
        let count = Int(((availableWidth + spacing) / (minimum + spacing)).rounded(.down))
        return max(count, 1)
    }
}
