import SwiftUI

struct SongRowView<Trailing: View>: View {
    let song: Song
    let artworkId: String
    let artworkURL: String
    var showTrackNumber: Bool = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder private let trailing: () -> Trailing

    init(
        song: Song,
        artworkId: String,
        artworkURL: String,
        showTrackNumber: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.song = song
        self.artworkId = artworkId
        self.artworkURL = artworkURL
        self.showTrackNumber = showTrackNumber
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
            if showTrackNumber, song.trackNumber > 0 {
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
/// have no local file, so they always show the "open official player" indicator instead of the
/// download controls; ordinary songs keep the download/queued/downloaded states.
struct SongRowDownloadTrailing: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        if song.isYouTube {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 18))
                .accessibilityLabel("YouTube 公式再生")
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
