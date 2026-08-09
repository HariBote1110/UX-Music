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

    private func songList(_ songs: [WatchTransferMeta]) -> some View {
        List(songs) { meta in
            WatchSongRow(meta: meta, queue: songs) { selectedPage = .nowPlaying }
        }
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
    var onSelect: () -> Void = {}

    var body: some View {
        Button {
            player.play(meta, queue: queue)
            onSelect()
        } label: {
            HStack {
                WatchArtworkThumbnail(meta: meta)
                    .frame(width: 28, height: 28)
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
    private static let thumbnailMaxPixelSize: CGFloat = 96

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
    private static func decodeThumbnail(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
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
