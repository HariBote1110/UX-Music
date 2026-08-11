import SwiftUI

/// Phase 1-3 browse UI: artwork-led, focus-based shelves (no text search as the primary
/// entry point — see `markdown/appletv-servermode-plan.md` §1-3). Reachable once
/// `TVAppModel.isPaired` is true.
///
/// Shelves: アルバム (from `Album.fromSongs`, matching desktop grouping) and プレイリスト
/// (`/v1/remote/playlists`). No 最近再生 (recently played) shelf — the LAN API exposes no
/// play-history endpoint (see `TVBrowseModel`'s doc comment and `progress/tvos-playback.md`).
/// No お気に入り shelf — the Mobile app has no favourites feature yet to mirror.
struct TVBrowseView: View {
    @ObservedObject var browseModel: TVBrowseModel
    @ObservedObject var playbackController: TVPlaybackController
    let player: MusicPlayerService
    let client: RemoteAPIClient
    let onSignOut: () -> Void

    /// Set to `true` whenever playback starts from the browse UI (Phase 2 "enter automatically"
    /// rule), and can also be flipped by the focusable Now Playing affordance below.
    @State private var nowPlayingPresented = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "tv.browse.title"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "tv.browse.signOut"), action: onSignOut)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    if player.currentSong != nil {
                        TVNowPlayingAffordance(player: player, client: client) {
                            nowPlayingPresented = true
                        }
                        .padding(.horizontal, 64)
                        .padding(.bottom, 24)
                    }
                }
        }
        .task { await browseModel.reload() }
        .fullScreenCover(isPresented: $nowPlayingPresented) {
            TVNowPlayingView(player: player, client: client)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch browseModel.loadState {
        case .idle, .loading:
            ProgressView()
        case .failed(let message):
            TVBrowseErrorView(message: message) {
                Task { await browseModel.reload() }
            }
        case .loaded:
            shelves
        }
    }

    private var shelves: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                if !browseModel.albums.isEmpty {
                    TVShelfSection(title: String(localized: "tv.browse.albums")) {
                        ForEach(browseModel.albums) { album in
                            TVAlbumCard(album: album, client: client) {
                                Task { await playFirstTrack(of: album) }
                            }
                        }
                    }
                }
                if !browseModel.playlists.isEmpty {
                    TVShelfSection(title: String(localized: "tv.browse.playlists")) {
                        ForEach(browseModel.playlists, id: \.name) { playlist in
                            TVPlaylistCard(playlist: playlist) {
                                Task { await playFirstTrack(of: playlist) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 32)
        }
    }

    private func playFirstTrack(of album: Album) async {
        guard let first = album.songs.first else { return }
        await playbackController.play(first, queue: album.songs)
        // Auto-enter Now Playing when playback starts from the browse UI (Phase 2 §1).
        nowPlayingPresented = true
    }

    /// Playlist tap → play-from-first with the rest queued, mirroring the album shelf's
    /// play-from-selection rule (§1-4's queue rule). `RemoteDesktopPlaylist` only carries
    /// `songIds` (not full `Song` values), so the ordered `Song` queue is derived here via
    /// `TVPlaylistQueueBuilder.songs(for:allSongs:)` — a pure function so the "unknown/missing
    /// song id" filtering is unit-testable without touching the browse model or network.
    private func playFirstTrack(of playlist: RemoteDesktopPlaylist) async {
        let orderedSongs = TVPlaylistQueueBuilder.songs(for: playlist, allSongs: browseModel.songs)
        guard let first = orderedSongs.first else { return }
        await playbackController.play(first, queue: orderedSongs)
        // Auto-enter Now Playing when playback starts from the browse UI (Phase 2 §1), same as albums.
        nowPlayingPresented = true
    }
}

/// Small focusable bar showing what's currently playing, with a tap target that opens the
/// full-screen Now Playing view — the "focusable now-playing affordance" entry point from the
/// Phase 2 plan, alongside the automatic-on-play-start entry above.
private struct TVNowPlayingAffordance: View {
    let player: MusicPlayerService
    let client: RemoteAPIClient
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                TVArtworkImage(artworkId: player.currentSong?.artworkId ?? "", client: client)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentSong?.title ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text(player.currentSong?.artist ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .padding(16)
        }
        .buttonStyle(.card)
        .accessibilityLabel(String(localized: "tv.nowPlaying.affordance"))
    }
}

private struct TVShelfSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 32) {
                    content
                }
                .padding(.vertical, 8)
            }
        }
    }
}

private struct TVAlbumCard: View {
    let album: Album
    let client: RemoteAPIClient
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                TVArtworkImage(artworkId: album.artworkId, client: client)
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Text(album.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(album.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 220)
        }
        .buttonStyle(.card)
    }
}

private struct TVPlaylistCard: View {
    let playlist: RemoteDesktopPlaylist
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.secondary.opacity(0.2))
                    .overlay(Image(systemName: "music.note.list").font(.system(size: 48)))
                    .frame(width: 220, height: 220)
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(1)
            }
            .frame(width: 220)
        }
        .buttonStyle(.card)
    }
}

/// Async artwork loader with a placeholder while loading/on failure, built on `AsyncImage`
/// against `RemoteAPIClient.artworkURL(artworkId:)` (which already embeds the `?token=` query
/// item — see that method's doc comment). TV-local rather than shared: the iOS artwork loader is
/// entangled with iOS's on-disk image cache, which isn't a clean fit for the OS-purgeable
/// `Caches` story tvOS uses (see `progress/tvos-playback.md`).
struct TVArtworkImage: View {
    let artworkId: String
    let client: RemoteAPIClient

    var body: some View {
        AsyncImage(url: artworkId.isEmpty ? nil : URL(string: client.artworkURL(artworkId: artworkId))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.secondary.opacity(0.2))
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
    }
}

private struct TVBrowseErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 72))
                .foregroundStyle(.yellow)
            Text(String(localized: "tv.browse.error.title"))
                .font(.title2)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
            Button(String(localized: "tv.browse.error.retry"), action: onRetry)
        }
        .padding()
    }
}
