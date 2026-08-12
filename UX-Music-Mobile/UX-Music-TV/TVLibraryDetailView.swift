import SwiftUI

/// Album/playlist detail screen (user report: album card tap must not start playback
/// immediately). Tapping an album or playlist card in `TVBrowseView` now opens this screen
/// instead of playing track 1 outright: a large artwork/glow header with a prominent 「再生」
/// button (plays from track 1), and a focusable track list where selecting a track plays from
/// that track with the rest queued — reusing the same play-from-selection queue rule the shelves
/// already used. One generic view backs both albums and playlists (`TVLibraryDetailContent`) to
/// keep the cinematic layout, focus styling, and queue-from-selection logic in one place.
/// See `progress/tvos-design.md`.
struct TVLibraryDetailContent: Identifiable {
    let id: String
    let title: String
    let artist: String
    /// `nil` for playlists (no single library artwork id to show) — falls back to a generic icon.
    let artworkId: String?
    let songs: [Song]

    static func album(_ album: Album) -> TVLibraryDetailContent {
        TVLibraryDetailContent(
            id: "album:\(album.id)",
            title: album.displayName,
            artist: album.displayArtist,
            artworkId: album.artworkId,
            songs: album.songs
        )
    }

    static func playlist(_ playlist: RemoteDesktopPlaylist, allSongs: [Song]) -> TVLibraryDetailContent {
        TVLibraryDetailContent(
            id: "playlist:\(playlist.name)",
            title: playlist.name,
            artist: "",
            artworkId: nil,
            songs: TVPlaylistQueueBuilder.songs(for: playlist, allSongs: allSongs)
        )
    }
}

struct TVLibraryDetailView: View {
    let content: TVLibraryDetailContent
    let client: RemoteAPIClient
    /// Called with the song to start from and the full queue (rest of the track list, in order).
    let onPlay: (Song, [Song]) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                trackList
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 48)
        }
        .background(TVCinematicBackground(intensity: 0.7))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 48) {
            artwork
                .frame(width: 320, height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: TVDesignTokens.signaturePink.opacity(0.35), radius: 40)

            VStack(alignment: .leading, spacing: 16) {
                Text(content.title)
                    .font(.system(size: 44, weight: .bold))
                    .lineLimit(2)
                if !content.artist.isEmpty {
                    Text(content.artist)
                        .font(.title3)
                        .foregroundStyle(TVDesignTokens.textSecondary)
                        .lineLimit(1)
                }
                if let first = content.songs.first {
                    Button {
                        onPlay(first, content.songs)
                    } label: {
                        Label(String(localized: "tv.detail.play"), systemImage: "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(TVCinematicCardStyle())
                    .padding(.top, 8)
                }
            }
            .padding(.top, 8)

            Spacer()
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let artworkId = content.artworkId {
            TVArtworkImage(artworkId: artworkId, client: client)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(.secondary.opacity(0.2))
                Image(systemName: "music.note.list")
                    .font(.system(size: 96))
                    .foregroundStyle(TVDesignTokens.textSecondary)
            }
        }
    }

    private var trackList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(content.songs.enumerated()), id: \.element.id) { index, song in
                Button {
                    onPlay(song, content.songs)
                } label: {
                    TVTrackRow(index: index + 1, song: song)
                }
                .buttonStyle(TVCinematicCardStyle())
            }
        }
    }
}

/// Small "PC" marker shown next to YouTube-sourced tracks (`Song.isYouTube`) so it's clear
/// selecting them plays through the desktop's official YouTube embed + LAN relay rather than local
/// playback (`progress/tvos-relay-reception.md` 追記). Deliberately subtle — a small pill, not a
/// full-size icon — to match the cinematic language's restraint (see `TVDesignTokens`).
struct TVRemotePlayBadge: View {
    var body: some View {
        Text(String(localized: "tv.remotePlay.badge"))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(TVDesignTokens.signaturePink.opacity(0.25), in: Capsule())
            .foregroundStyle(.white)
    }
}

private struct TVTrackRow: View {
    let index: Int
    let song: Song

    var body: some View {
        HStack(spacing: 20) {
            Text("\(index)")
                .font(.body.monospacedDigit())
                .foregroundStyle(TVDesignTokens.textSecondary)
                .frame(width: 32, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(song.title)
                        .font(.headline)
                        .lineLimit(1)
                    if song.isYouTube {
                        TVRemotePlayBadge()
                    }
                }
                if !song.artist.isEmpty {
                    Text(song.artist)
                        .font(.subheadline)
                        .foregroundStyle(TVDesignTokens.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(Self.formatDuration(song.duration))
                .font(.body.monospacedDigit())
                .foregroundStyle(TVDesignTokens.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#if DEBUG
/// Preview-only harness for `UXTV_PREVIEW=albumdetail` (see `UXMusicTVApp`), rendering
/// `TVLibraryDetailView` with stub tracks so the detail layout can be screenshotted without
/// pairing. See `progress/tvos-design.md`.
struct TVLibraryDetailPreviewHarness: View {
    private let client = RemoteAPIClient(baseURLString: "http://198.51.100.1:9999")

    private static let content = TVLibraryDetailContent(
        id: "preview-album",
        title: "デモアルバム 1",
        artist: "UX Music Demo",
        artworkId: "preview-1",
        songs: (1 ... 6).map { i in
            Song(
                id: "song-\(i)",
                path: "",
                title: "デモ曲 \(i) - とても長いタイトルの場合の確認用テキストです",
                artist: "UX Music Demo",
                duration: Double(150 + i * 7)
            )
        }
    )

    var body: some View {
        TVLibraryDetailView(content: Self.content, client: client) { _, _ in }
    }
}

/// Preview-only harness for `UXTV_PREVIEW=youtubebadge` (`progress/tvos-relay-reception.md` 追記):
/// a detail screen with one local track and one YouTube-sourced stub track (`sourceType: .youtube`)
/// so `TVRemotePlayBadge` (the small "PC" marker on `TVTrackRow`) can be screenshotted without
/// pairing/network.
struct TVYouTubeBadgePreviewHarness: View {
    private let client = RemoteAPIClient(baseURLString: "http://198.51.100.1:9999")

    private static let content = TVLibraryDetailContent(
        id: "preview-youtubebadge",
        title: "デモアルバム（YouTube混在）",
        artist: "UX Music Demo",
        artworkId: "preview-1",
        songs: [
            Song(id: "local-1", path: "/a.mp3", title: "ローカル曲", artist: "UX Music Demo", duration: 180),
            Song(
                id: "yt-1",
                path: "",
                title: "YouTube由来の曲 - PC経由で再生されます",
                artist: "UX Music Demo",
                duration: 210,
                sourceType: .youtube
            ),
        ]
    )

    var body: some View {
        TVLibraryDetailView(content: Self.content, client: client) { _, _ in }
    }
}
#endif
