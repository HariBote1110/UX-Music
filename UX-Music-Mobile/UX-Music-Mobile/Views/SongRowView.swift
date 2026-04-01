import SwiftUI

struct SongRowView<Trailing: View>: View {
    let song: Song
    let artworkURL: String
    var showTrackNumber: Bool = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder private let trailing: () -> Trailing

    init(
        song: Song,
        artworkURL: String,
        showTrackNumber: Bool = false,
        onTap: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.song = song
        self.artworkURL = artworkURL
        self.showTrackNumber = showTrackNumber
        self.onTap = onTap
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingCluster
            Spacer(minLength: 0)
            trailing()
        }
    }

    /// Tappable for play only when `onTap` is set. Must not wrap `trailing()` in a disabled `Button`, or
    /// download controls stay inactive while the song is not yet local.
    private var leadingCluster: some View {
        HStack(spacing: 12) {
            if showTrackNumber, song.trackNumber > 0 {
                Text("\(song.trackNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .center)
            } else {
                ArtworkImageView(urlString: artworkURL, size: 48)
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
        .contentShape(Rectangle())
        .modifier(OptionalRowTap(onTap: onTap))
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
