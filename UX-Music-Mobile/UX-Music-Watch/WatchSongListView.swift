import ImageIO
import SwiftUI
import UIKit

/// Library page: a plain native `List` with two `NavigationLink` rows ("Songs"/"Albums") pushing
/// the flat song list and the album list respectively — the same drill-down pattern watchOS's own
/// Music app uses for its library, rather than a custom segmented-style toggle. Tapping a song row
/// starts playback and switches to the Now Playing page (see `WatchRootView`'s paged `TabView`).
/// Deletion is a long-press context menu rather than a row swipe: on watchOS the Library and Now
/// Playing/Queue pages are themselves swiped between horizontally (see `WatchRootView`), and a
/// right-swipe on a list row was being captured by the row's own `swipeActions` instead of the page
/// `TabView`, making it impossible to swipe from Library to Now Playing while a finger started on a
/// row. A long press has no such conflict.
struct WatchSongListView: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    @Binding var selectedPage: WatchPage

    private var albums: [WatchAlbumGroup] { WatchAlbumGrouping.albums(from: library.songs) }

    var body: some View {
        NavigationStack {
            Group {
                if library.songs.isEmpty {
                    Text("曲がありません\niPhone アプリから転送してください")
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    List {
                        NavigationLink {
                            songList(library.songs)
                                .navigationTitle("曲")
                        } label: {
                            Label("曲", systemImage: "music.note")
                        }
                        NavigationLink {
                            albumList
                        } label: {
                            Label("アルバム", systemImage: "square.stack")
                        }
                    }
                }
            }
            .navigationTitle("ライブラリ")
        }
    }

    /// The flat "Songs" list, sorted into album order (see `WatchAlbumGrouping.songsSortedByAlbum`)
    /// so consecutive same-album rows actually form runs, then rendered with the album-run
    /// connector (see `WatchSongRowMetrics`'s doc comment) — the app's signature list style,
    /// already on iOS/desktop, trialled here first per the album detail list and the Queue &
    /// Volume page, which deliberately keep their previous look (`WatchSongRow.albumGroupPosition`
    /// stays at its `nil` default there).
    private func songList(_ songs: [WatchTransferMeta]) -> some View {
        let sorted = WatchAlbumGrouping.songsSortedByAlbum(songs)
        let groupPositions = AlbumGrouping.positions(forAlbumKeys: sorted.map(\.displayAlbum))
        return List {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, meta in
                WatchSongRow(
                    meta: meta,
                    queue: sorted,
                    albumGroupPosition: groupPositions[index]
                ) { selectedPage = .nowPlaying }
                    .modifier(WatchLibraryListRowStyle())
            }
        }
        // Removes watchOS's default per-row card chrome/spacing — see `WatchLibraryListRowStyle`'s
        // doc comment for why that spacing (not a separator line) is what would otherwise break the
        // connector's continuity between rows.
        .listStyle(.plain)
    }

    private var albumList: some View {
        List(albums) { album in
            NavigationLink {
                WatchAlbumDetailView(album: album, selectedPage: $selectedPage)
            } label: {
                HStack {
                    WatchArtworkThumbnail(meta: album.artworkSong)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.album)
                            .font(.body)
                            .lineLimit(1)
                        Text("\(album.songs.count)曲")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("アルバム")
    }
}

/// One song's worth of an album's track list, shown by `WatchAlbumDetailView`. Tapping a track
/// starts the whole album playing as the queue (in track order), positioned at that track — not
/// just the single song — matching how tapping a track in an album normally behaves.
private struct WatchAlbumDetailView: View {
    let album: WatchAlbumGroup
    @Binding var selectedPage: WatchPage

    var body: some View {
        List(album.songs) { meta in
            WatchSongRow(meta: meta, queue: album.songs) { selectedPage = .nowPlaying }
        }
        .navigationTitle(album.album)
    }
}

/// Watch-side analogue of the iOS app's `SongRowMetrics` (`Views/SongRowView.swift`): sized for the
/// Watch's much smaller screen (~150-176pt usable width, ~242pt height) rather than reusing the iOS
/// numbers directly. `artworkSize` is unchanged from the row's original fixed 28pt thumbnail frame
/// (already within the 28-32pt Watch range) so lists that opt out of the album-run connector
/// (`WatchSongRow.albumGroupPosition == nil`: album detail, Queue & Volume) keep their exact prior
/// look — only `rowHeight`/`WatchLibraryListRowStyle` are new, and both are applied only where the
/// connector is opted into (see `WatchSongRow.body`).
///
/// `rowHeight` is fixed and `WatchLibraryListRowStyle` adds no vertical row padding, so consecutive
/// rows touch exactly — the same invariant the connector line needs on iOS (`LibraryListRowStyle`'s
/// doc comment): any gap between rows makes the line look chopped at the boundary.
enum WatchSongRowMetrics {
    static let artworkSize: CGFloat = 28
    static let rowHeight: CGFloat = 46
    /// Horizontal inset of a row's content from the screen edge.
    static let horizontalInset: CGFloat = 8
}

/// Applied only to rows opted into the album-run connector (see `WatchSongRowMetrics`'s doc
/// comment) — the flat "Songs" list. Mirrors iOS's `LibraryListRowStyle`: rows carry no background
/// of their own so the connector line reads as one continuous line rather than something sliced
/// per row.
///
/// No `.listRowSeparator(.hidden)` here — that modifier is unavailable on watchOS (it fails to
/// compile: `'listRowSeparator(_:edges:)' is unavailable in watchOS`). `songList(_:)` instead sets
/// `.listStyle(.plain)` on the `List` itself, which is what actually removes watchOS's default
/// per-row card chrome/spacing (the default style otherwise inserts a visible gap between rows,
/// which would break the connector line's continuity regardless of this modifier).
struct WatchLibraryListRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: WatchSongRowMetrics.horizontalInset,
                bottom: 0,
                trailing: WatchSongRowMetrics.horizontalInset
            ))
            .listRowBackground(Color.clear)
    }
}

/// A single tappable song row shared by the flat song list, the album detail list, and the
/// Queue & Volume page's "up next" list (see `WatchQueueVolumeView`): starts playback of `queue`
/// from `meta` and invokes `onSelect` (e.g. switching to Now Playing on the Library pages; a no-op
/// on the Queue page, which stays put). Offers "Delete" via a long-press context menu (see
/// `WatchSongListView`'s doc comment for why this replaced row swipe actions).
struct WatchSongRow: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    @EnvironmentObject private var player: WatchAudioPlayerService
    let meta: WatchTransferMeta
    let queue: [WatchTransferMeta]
    /// This row's position within a run of consecutive same-album rows in `queue`'s current order
    /// — see `AlbumGroupPosition` and `WatchSongListView.songList(_:)`, the only caller that
    /// computes this today. `nil` (the default) keeps this row's original variable-height,
    /// system-default list styling and always-shown artwork: the album detail list and the
    /// Queue & Volume page deliberately do not opt into the connector yet (see
    /// `progress/watch-ui-redesign.md`), matching how `SongRowView` opts in on iOS.
    var albumGroupPosition: AlbumGroupPosition? = nil
    var onSelect: () -> Void = {}

    var body: some View {
        Button {
            player.play(meta, queue: queue)
            onSelect()
        } label: {
            HStack {
                leadingSlot
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.displayTitle)
                        .font(.body)
                        .lineLimit(1)
                    Text(meta.displayArtist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if player.currentSong?.id == meta.id {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GroupedRowHeight(isGrouped: albumGroupPosition != nil))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                library.removeSong(id: meta.id)
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    /// Artwork, or the album-run connector — always the same width so titles line up. A `.first`
    /// row shows *both*: the artwork plus the stub of line beneath it that joins the next row's
    /// connector (see `AlbumGroupConnector`'s doc comment).
    @ViewBuilder
    private var leadingSlot: some View {
        if let position = albumGroupPosition, position != .single {
            ZStack {
                WatchAlbumGroupConnectorView(position: position)
                if position == .first {
                    WatchArtworkThumbnail(meta: meta)
                        .frame(width: WatchSongRowMetrics.artworkSize, height: WatchSongRowMetrics.artworkSize)
                }
            }
            .frame(width: WatchSongRowMetrics.artworkSize)
        } else {
            WatchArtworkThumbnail(meta: meta)
                .frame(width: WatchSongRowMetrics.artworkSize, height: WatchSongRowMetrics.artworkSize)
        }
    }
}

/// Fixes the row's height to `WatchSongRowMetrics.rowHeight` only when the row has opted into the
/// album-run connector — lists that have not (album detail, Queue & Volume) keep their original
/// system-default row height, unchanged. See `WatchSongRowMetrics`'s doc comment for why the fixed
/// height matters wherever the connector is actually drawn.
private struct GroupedRowHeight: ViewModifier {
    let isGrouped: Bool

    func body(content: Content) -> some View {
        if isGrouped {
            content.frame(height: WatchSongRowMetrics.rowHeight)
        } else {
            content
        }
    }
}

/// Watch analogue of the iOS `AlbumGroupConnectorView` (`Views/SongRowView.swift`): draws the
/// vertical line — and, on a run's last row, the `└` elbow — in place of/under a row's artwork for
/// a run of consecutive same-album rows. See `AlbumGroupConnector` for the pure geometry this reads;
/// this view only turns that geometry into a `Canvas` stroke.
///
/// Takes the row's *whole* height (no fixed height of its own, so the enclosing `HStack`'s proposal
/// fills it) rather than `WatchSongRowMetrics.artworkSize` — drawing at the artwork's height would
/// leave a gap at each row boundary and make the line look chopped, the same pitfall iOS's version
/// avoids.
private struct WatchAlbumGroupConnectorView: View {
    let position: AlbumGroupPosition
    private let lineWidth: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            guard let segment = AlbumGroupConnector.verticalSegment(
                for: position,
                rowHeight: size.height,
                artworkSize: WatchSongRowMetrics.artworkSize
            ) else { return }
            let midX = size.width / 2
            var path = Path()
            path.move(to: CGPoint(x: midX, y: segment.fromY))
            path.addLine(to: CGPoint(x: midX, y: segment.toY))
            if AlbumGroupConnector.hasElbow(for: position) {
                path.addLine(to: CGPoint(x: size.width, y: segment.toY))
            }
            context.stroke(path, with: .color(Color.secondary.opacity(0.35)), lineWidth: lineWidth)
        }
        .frame(width: WatchSongRowMetrics.artworkSize)
    }
}

/// Shared decoded-artwork cache for every Watch song row (Library "Songs"/"Albums" lists, album
/// detail, Queue & Volume — anywhere `WatchArtworkThumbnail` is used). See `ArtworkMemoryCache`'s
/// doc comment for why this exists (and how its capacity/eviction policy is tested) and
/// `WatchArtworkThumbnail`'s doc comment for the decode this caches.
///
/// Capacity of 80: entries are decoded at `WatchArtworkThumbnail.thumbnailMaxPixelSize` (~96px),
/// not the full ~400px JPEG the iPhone transfers (see `WatchTransferBridge
/// .writeDownscaledArtwork`), so 80 entries is roughly 80 × 36KB ≈ 2.9MB — comfortably inside
/// watchOS's per-app memory budget while covering far more rows than a Watch screen ever shows at
/// once.
private enum WatchArtworkCache {
    static let shared = ArtworkMemoryCache<UIImage>(capacity: 80)
}

/// Small library-row thumbnail: the received-artwork JPEG if present, otherwise a generic note
/// glyph placeholder. Kept as its own view (rather than inline in the `List`) so each row only
/// resolves its own artwork, not the whole list's. `meta` is optional so the album list can reuse
/// this for `WatchAlbumGroup.artworkSong`, which is `nil` only for a (never-expected) empty album.
///
/// Decoding used to happen synchronously inside `body` (`Data(contentsOf:)` + `UIImage(data:)`),
/// which re-read and re-decoded the JPEG from disk **on the main thread on every SwiftUI render
/// pass** — including passes triggered by unrelated `@Published` changes on
/// `WatchAudioPlayerService`, which every row observes. `WatchNowPlayingView` already solved this
/// for its one full-bleed image (see its `cachedArtworkImage` doc comment); this view now gets the
/// same treatment: a placeholder shows until the decode finishes, the actual decode happens off the
/// main thread, and the result is kept in `WatchArtworkCache` so a song already seen this session is
/// resolved from memory rather than decoded again.
private struct WatchArtworkThumbnail: View {
    @EnvironmentObject private var library: WatchLocalLibrary
    let meta: WatchTransferMeta?
    @State private var image: UIImage?

    /// Long-edge pixel size to decode artwork thumbnails at. The transferred JPEG is ~400px long
    /// edge (see `WatchTransferBridge.writeDownscaledArtwork`), far larger than this row ever draws
    /// it (`WatchSongRowMetrics.artworkSize`, 28pt) — decoding straight to a small thumbnail via
    /// ImageIO avoids ever allocating a full-size decoded bitmap, which is what keeps
    /// `WatchArtworkCache`'s per-entry footprint small.
    nonisolated private static let thumbnailMaxPixelSize: CGFloat = 96

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                Image(systemName: "music.note")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        // `.task(id:)` re-runs only when `meta?.id` actually changes (and cancels the previous
        // attempt if it does) — unlike plain code in `body`, it does *not* re-fire on every redraw,
        // which is what let unrelated `@Published` churn re-trigger a decode before.
        .task(id: meta?.id) {
            image = await Self.resolvedImage(for: meta, library: library)
        }
    }

    private static func resolvedImage(for meta: WatchTransferMeta?, library: WatchLocalLibrary) async -> UIImage? {
        guard let meta else { return nil }
        if let cached = WatchArtworkCache.shared.value(forKey: meta.id) {
            return cached
        }
        guard let url = library.artworkFileURLIfPresent(for: meta) else { return nil }
        // `.detached` so the decode genuinely runs off the main actor regardless of what actor
        // `.task` inherited from its caller — confirmed off-main by sampling the running app (see
        // `progress/watch-ui-redesign.md`).
        let decoded = await Task.detached(priority: .utility) { () -> UIImage? in
            decodeThumbnail(at: url, maxPixelSize: thumbnailMaxPixelSize)
        }.value
        if let decoded {
            WatchArtworkCache.shared.setValue(decoded, forKey: meta.id)
        }
        return decoded
    }

    /// Decodes straight to a small bitmap via ImageIO's thumbnail generator rather than
    /// `UIImage(data:)` followed by a separate resize: ImageIO never allocates a full-size decoded
    /// bitmap at all when a smaller target is requested, so this is both lighter and faster than
    /// decode-then-downsize for a row-sized thumbnail.
    ///
    /// `nonisolated` because `WatchArtworkThumbnail` is a `View` (implicitly main-actor-isolated,
    /// like `body`) but this must run inside `Task.detached` genuinely off the main actor — without
    /// this, calling it from the detached closure is an implicit actor hop the compiler flags as a
    /// missing `await` (`-Xfrontend -strict-concurrency` warning, an error under Swift 6 mode).
    nonisolated private static func decodeThumbnail(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    WatchSongListView(selectedPage: .constant(.library))
        .environmentObject(WatchLocalLibrary())
        .environmentObject(WatchAudioPlayerService(library: WatchLocalLibrary()))
}
