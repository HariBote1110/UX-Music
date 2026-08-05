import SwiftUI

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
    var body: some View {
        HStack(spacing: 12) {
            leadingCluster
            Spacer(minLength: 0)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(OptionalRowTap(onTap: onTap))
    }

    private var leadingCluster: some View {
        HStack(spacing: 12) {
            if let position = albumGroupPosition, position == .middle || position == .last {
                AlbumGroupConnectorView(position: position)
            } else if showTrackNumber, song.trackNumber > 0 {
                Text("\(song.trackNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .center)
            } else {
                ArtworkImageView(artworkId: artworkId, urlString: artworkURL, size: 48)
            }
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
/// `createSongItem`, ~line 62–140): drawn in place of the artwork for interior/last rows of a
/// consecutive same-album run. `.middle` rows get a full-height line down the centre; `.last` rows
/// get a line from the top down to the centre, then an elbow running right — the `└` the desktop
/// draws to visually "close" the group under its first row's artwork. `--text-muted` becomes
/// `Color.secondary` at low opacity, the closest mobile analogue.
private struct AlbumGroupConnectorView: View {
    let position: AlbumGroupPosition
    private let slotSize: CGFloat = 48
    private let lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let midX = size.width / 2
            let midY = size.height / 2
            var path = Path()
            switch position {
            case .middle:
                path.move(to: CGPoint(x: midX, y: 0))
                path.addLine(to: CGPoint(x: midX, y: size.height))
            case .last:
                path.move(to: CGPoint(x: midX, y: 0))
                path.addLine(to: CGPoint(x: midX, y: midY))
                path.addLine(to: CGPoint(x: size.width, y: midY))
            case .single, .first:
                break
            }
            context.stroke(path, with: .color(Color.secondary.opacity(0.35)), lineWidth: lineWidth)
        }
        .frame(width: slotSize, height: slotSize)
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
