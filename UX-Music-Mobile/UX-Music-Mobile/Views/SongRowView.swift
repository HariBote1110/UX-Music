import SwiftUI

/// Shared metrics for every list of songs. The row height is *fixed* and callers add no vertical
/// padding of their own, so consecutive rows touch exactly — that is what lets the album-run
/// connector line (`AlbumGroupConnector`) run unbroken from one row into the next.
enum SongRowMetrics {
    static let artworkSize: CGFloat = 48
    static let rowHeight: CGFloat = 64
    /// Horizontal inset of a row's content from the screen edge.
    static let horizontalInset: CGFloat = 16
}

/// Flat, full-bleed background for library list rows.
///
/// Rows used to be individual `RoundedRectangle` cards inset 8pt from each edge; packed together
/// with no gap between them the rounded corners just produced odd slivers of black along the screen
/// edges. Rows now carry no fill of their own at all and sit directly on the screen's black — one
/// uninterrupted surface, which is also what makes the album connector line read as joined up
/// rather than sliced per card.
///
/// A slightly-lighter row fill (the old `0.07` card colour, spanning the full width) was tried
/// first and looked worse: wherever the list's content ended — under the tab bar, above the mini
/// player — the slab stopped against the black background as a hard horizontal seam cutting a row
/// in half. Matching the page background removes the seam entirely.
struct LibraryListRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: SongRowMetrics.horizontalInset,
                bottom: 0,
                trailing: SongRowMetrics.horizontalInset
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

struct SongRowView<Trailing: View>: View {
    let song: Song
    let artworkId: String
    let artworkURL: String
    var showTrackNumber: Bool = false
    /// This row's position within a run of consecutive same-album rows (see `AlbumGrouping
    /// .positions`). `nil` (the default) keeps the previous unconditional-artwork behaviour so
    /// every existing call site compiles unchanged; callers opt in by passing the computed
    /// position only when their list is in album order.
    var albumGroupPosition: AlbumGroupPosition? = nil
    var onTap: (() -> Void)? = nil
    @ViewBuilder private let trailing: () -> Trailing

    init(
        song: Song,
        artworkId: String,
        artworkURL: String,
        showTrackNumber: Bool = false,
        albumGroupPosition: AlbumGroupPosition? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.song = song
        self.artworkId = artworkId
        self.artworkURL = artworkURL
        self.showTrackNumber = showTrackNumber
        self.albumGroupPosition = albumGroupPosition
        self.onTap = onTap
        self.trailing = trailing
    }

    /// Tappable for play across the whole row (including the trailing spacer) when `onTap` is set.
    /// The gesture and content shape live on the outer HStack so empty space is tappable too. Must
    /// not wrap `trailing()` in a disabled `Button`, or download controls stay inactive while the
    /// song is not yet local; placing `trailing()`'s own Button on top lets it win the hit-test over
    /// the row-level tap gesture.
    /// The row height is fixed (`SongRowMetrics.rowHeight`) rather than derived from the content so
    /// that stacked rows leave no gap for the album connector line to fall through, and so every
    /// list of songs scrolls with a uniform rhythm.
    var body: some View {
        HStack(spacing: 12) {
            leadingCluster
            Spacer(minLength: 0)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SongRowMetrics.rowHeight)
        .contentShape(Rectangle())
        .modifier(OptionalRowTap(onTap: onTap))
    }

    private var leadingCluster: some View {
        HStack(spacing: 12) {
            leadingSlot
            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(showTrackNumber ? song.formattedDuration : "\(song.displayArtist) · \(song.formattedDuration)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Artwork, track number, or album-run connector — always the same width so titles line up.
    /// A `.first` row shows *both*: the artwork plus the stub of line beneath it that joins the
    /// next row's connector.
    @ViewBuilder
    private var leadingSlot: some View {
        if let position = albumGroupPosition, position != .single {
            ZStack {
                AlbumGroupConnectorView(position: position)
                if position == .first {
                    ArtworkImageView(artworkId: artworkId, urlString: artworkURL, size: SongRowMetrics.artworkSize)
                }
            }
            .frame(width: SongRowMetrics.artworkSize)
        } else if showTrackNumber, song.trackNumber > 0 {
            Text("\(song.trackNumber)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)
        } else {
            ArtworkImageView(artworkId: artworkId, urlString: artworkURL, size: SongRowMetrics.artworkSize)
        }
    }
}

/// Queue actions offered by a song row's long-press menu. The library screens page horizontally
/// between segments now, so row swipe actions are gone — the context menu is where every per-song
/// control lives. `song` must already be resolved for playback (local path filled in) by the
/// calling screen, exactly as it would be for `MusicPlayerService.play`.
struct SongQueueMenuItems: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        Button {
            model.player.insertNext(song)
        } label: {
            Label("次に再生", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            model.player.appendToQueue(song)
        } label: {
            Label("最後に追加", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
    }
}

/// Long-press submenu that files a song into one of the user's playlists. Hidden entirely when
/// there are no playlists yet, rather than showing an empty menu.
struct AddSongToPlaylistMenuItem: View {
    @Environment(AppModel.self) private var model
    let songId: String

    var body: some View {
        if !model.playlists.isEmpty {
            Menu {
                ForEach(model.playlists) { playlist in
                    Button(playlist.name) {
                        try? model.addSongsToPlaylist(playlistId: playlist.id, songIds: [songId])
                    }
                }
            } label: {
                Label("プレイリストに追加", systemImage: "text.badge.plus")
            }
        }
    }
}

/// Trailing indicator shared by every screen that lists songs via `SongRowView`. YouTube songs
/// have no local file, so instead of the download controls they show a "ライブラリに追加" action
/// (a checkmark once the song is already a Library member — see `AppModel.libraryMembershipStore`);
/// ordinary songs keep the download/queued/downloaded states.
struct SongRowDownloadTrailing: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        if song.isYouTube {
            if model.isLibrarySongMember(songId: song.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 20))
                    .accessibilityLabel("ライブラリに追加済み")
            } else {
                Button {
                    model.addYouTubeSongToLibrary(song)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("ライブラリに追加")
            }
        } else if model.isSongDownloaded(songId: song.id) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 20))
        } else if let p = model.downloadProgress[song.id] {
            Group {
                if p > 0 {
                    ProgressView(value: p, total: 1)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 22, height: 22)
        } else {
            Button {
                Task { await model.downloadSong(song) }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Mobile equivalent of the desktop's `groupAlbumArt` connector (`element-factory.ts`'s
/// `createSongItem`, ~line 62–140): the vertical rule that ties a run of consecutive same-album rows
/// together, with an elbow (`└`) closing the run on its last row. `--text-muted` becomes
/// `Color.secondary` at low opacity, the closest mobile analogue.
///
/// The canvas takes the *whole* row height (no fixed height of its own, so the enclosing `HStack`'s
/// proposal fills it) — drawing it at the artwork's 48pt used to leave a gap at each row boundary,
/// which is what made the line look chopped up. `AlbumGroupConnector` owns the actual y-coordinates.
private struct AlbumGroupConnectorView: View {
    let position: AlbumGroupPosition
    private let lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            guard let segment = AlbumGroupConnector.verticalSegment(
                for: position,
                rowHeight: size.height,
                artworkSize: SongRowMetrics.artworkSize
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
        .frame(width: SongRowMetrics.artworkSize)
    }
}

private struct OptionalRowTap: ViewModifier {
    let onTap: (() -> Void)?

    func body(content: Content) -> some View {
        if let onTap {
            content
                .onTapGesture { onTap() }
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}
