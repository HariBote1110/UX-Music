import SwiftUI
import UIKit

/// The one full-screen cover `TVBrowseView` can have up at a time — see `presentation`'s doc
/// comment on why this replaced three independent `.fullScreenCover` modifiers.
enum TVBrowsePresentation: Identifiable, Equatable {
    case nowPlaying
    case detail(TVLibraryDetailContent)
    case relay
    /// "PC経由で再生中" flow (`progress/tvos-relay-reception.md` 追記): shown while a YouTube-sourced
    /// song selection is being sent to the host and while waiting for `relay.active` to flip true.
    case remotePlaySong

    var id: String {
        switch self {
        case .nowPlaying: return "nowPlaying"
        case .detail(let content): return "detail:\(content.id)"
        case .relay: return "relay"
        case .remotePlaySong: return "remotePlaySong"
        }
    }

    static func == (lhs: TVBrowsePresentation, rhs: TVBrowsePresentation) -> Bool {
        lhs.id == rhs.id
    }
}

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
    @ObservedObject var relayModel: TVRelayModel
    @ObservedObject var relayPlaybackController: TVRelayPlaybackController
    @StateObject private var remotePlaySongCoordinator: TVRemotePlaySongCoordinator
    let player: MusicPlayerService
    let client: RemoteAPIClient
    let onSignOut: () -> Void

    init(
        browseModel: TVBrowseModel,
        playbackController: TVPlaybackController,
        relayModel: TVRelayModel,
        relayPlaybackController: TVRelayPlaybackController,
        player: MusicPlayerService,
        client: RemoteAPIClient,
        onSignOut: @escaping () -> Void
    ) {
        self.browseModel = browseModel
        self.playbackController = playbackController
        self.relayModel = relayModel
        self.relayPlaybackController = relayPlaybackController
        self.player = player
        self.client = client
        self.onSignOut = onSignOut
        _remotePlaySongCoordinator = StateObject(
            wrappedValue: TVRemotePlaySongCoordinator(client: client, relayPlaybackController: relayPlaybackController)
        )
    }

    /// Single source of truth for whichever full-screen cover is up (Now Playing / detail /
    /// relay banner), replacing three sibling `.fullScreenCover` modifiers that used to drive
    /// independently. Regression root cause (see `progress/tvos-design.md`): dismissing the
    /// detail cover (`presentedDetail = nil`) and presenting the Now Playing cover
    /// (`nowPlayingPresented = true`) on two *separate* `.fullScreenCover` modifiers races on
    /// tvOS — the dismiss of one and the present of the other, both driven from the same
    /// presenting view, aren't sequenced by SwiftUI, so the second present can be dropped and the
    /// user is left on a stale/initial screen. A single `.fullScreenCover(item:)` switching over
    /// one `@State` enum makes cover-to-cover transitions (detail → Now Playing) go through one
    /// presentation context instead of two, which SwiftUI handles reliably.
    @State private var presentation: TVBrowsePresentation?

    var body: some View {
        NavigationStack {
            content
                // The system nav title reads weak/centred on tvOS; a left-aligned, higher-contrast
                // `TVBrowseHeader` inside `shelves` carries the heading instead (user feedback —
                // see `progress/tvos-design.md`). The system title is kept empty (not removed
                // entirely) so the toolbar's sign-out item still has a navigation bar to sit in.
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "tv.browse.signOut"), action: onSignOut)
                    }
                }
                .background(TVCinematicBackground(intensity: 0.6))
                .safeAreaInset(edge: .bottom) {
                    if player.currentSong != nil {
                        TVNowPlayingAffordance(player: player, client: client) {
                            presentation = .nowPlaying
                        }
                        .padding(.horizontal, 64)
                        .padding(.bottom, 24)
                    }
                }
        }
        .task { await browseModel.reload() }
        .fullScreenCover(item: $presentation) { presented in
            switch presented {
            case .nowPlaying:
                TVNowPlayingView(player: player, client: client)
            case .detail(let content):
                TVLibraryDetailView(content: content, client: client) { song, queue in
                    Task { await play(song, queue: queue) }
                }
            case .relay:
                TVRelayBannerView(relayModel: relayModel, relayPlaybackController: relayPlaybackController, client: client) {
                    presentation = nil
                }
            case .remotePlaySong:
                TVRemotePlaySongWaitingView(coordinator: remotePlaySongCoordinator) {
                    remotePlaySongCoordinator.cancel()
                    presentation = nil
                }
            }
        }
        // If the host stops relaying while the banner is up (e.g. the PC operator paused or
        // closed the YouTube embed), exit the banner rather than leaving a dead stream on screen.
        .onChange(of: relayModel.isAvailable) { _, isAvailable in
            if presentation == .relay && !isAvailable {
                presentation = nil
            }
        }
        // Once the "PC経由で再生中" flow observes `relay.active` and starts
        // `relayPlaybackController`, hand off from the waiting screen to the same relay banner the
        // "PCで再生中のYouTube" shelf entry uses.
        .onChange(of: remotePlaySongCoordinator.state) { _, state in
            if presentation == .remotePlaySong, case .active = state {
                presentation = .relay
            }
        }
    }

    /// Pauses local playback and switches to the host's YouTube relay stream (Phase 3-3 §3-3).
    private func playRelay() {
        player.stop()
        relayPlaybackController.start()
        presentation = .relay
    }

    /// Selecting a YouTube-sourced song (browse shelf or detail track list): pauses local
    /// playback and sends `play-song` to the host, then waits for the relay to come up
    /// (`progress/tvos-relay-reception.md` 追記).
    private func playViaPC(_ song: Song) {
        player.stop()
        remotePlaySongCoordinator.start(songId: song.id)
        presentation = .remotePlaySong
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
                TVBrowseHeader()
                if relayModel.isAvailable {
                    TVShelfSection(title: String(localized: "tv.browse.relay")) {
                        TVRelayCard(
                            title: relayModel.title,
                            thumbnailURLString: relayModel.thumbnail,
                            onSelect: playRelay
                        )
                    }
                }
                if !browseModel.albums.isEmpty {
                    TVShelfSection(title: String(localized: "tv.browse.albums")) {
                        ForEach(browseModel.albums) { album in
                            TVAlbumCard(album: album, client: client) {
                                presentation = .detail(.album(album))
                            }
                        }
                    }
                }
                if !browseModel.playlists.isEmpty {
                    TVShelfSection(title: String(localized: "tv.browse.playlists")) {
                        ForEach(browseModel.playlists, id: \.name) { playlist in
                            TVPlaylistCard(playlist: playlist) {
                                presentation = .detail(.playlist(playlist, allSongs: browseModel.songs))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 32)
        }
    }

    /// Plays `song` with `queue` behind it — used by both the album and playlist detail screens'
    /// 「再生」 button (`queue.first`) and per-track selection (play-from-selection, §1-4's queue
    /// rule). `RemoteDesktopPlaylist`'s queue is pre-derived by `TVLibraryDetailContent.playlist`
    /// via `TVPlaylistQueueBuilder.songs(for:allSongs:)` before reaching here.
    private func play(_ song: Song, queue: [Song]) async {
        // Selection-routing decision (`TVSongPlaybackRouting`): YouTube-sourced songs have no
        // audio the TV can stream directly, so they play via the paired PC's own playback + LAN
        // relay instead of the local `TVPlaybackController` path.
        switch TVSongPlaybackRouting.route(for: song) {
        case .viaPC:
            playViaPC(song)
        case .local:
            await playbackController.play(song, queue: queue)
            // Auto-enter Now Playing when playback starts from the browse UI (Phase 2 §1), whether
            // called from a shelf tap (no cover up yet) or from the detail screen's track selection
            // (replaces the still-presented detail cover with Now Playing in one step — see
            // `presentation`'s doc comment above for why this must go through a single
            // `.fullScreenCover(item:)` rather than a dismiss-then-present pair).
            presentation = .nowPlaying
        }
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
                        .foregroundStyle(TVDesignTokens.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .padding(16)
        }
        .buttonStyle(TVCinematicCardStyle())
        .accessibilityLabel(String(localized: "tv.nowPlaying.affordance"))
    }
}

/// Left-aligned, higher-contrast "UX Music" heading (user feedback: the previous centred system
/// nav title read weak/muted). Deliberately modest — a headline weight, not an oversized hero —
/// per the cinematic language's restraint. See `progress/tvos-design.md`.
private struct TVBrowseHeader: View {
    var body: some View {
        Text(String(localized: "tv.browse.title"))
            .font(.system(size: 40, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                // `.frame(width:)` + `.truncationMode` on each label (not just the parent VStack),
                // plus a small horizontal inset, so text truncates to the card's footprint even
                // under the focus `scaleEffect` instead of sitting flush against the rounded card
                // corner — user report: focused labels were spilling past the card edge / getting
                // clipped by the corner radius rather than truncating cleanly. See
                // `progress/tvos-design.md`.
                Text(album.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
                    .frame(width: 220, alignment: .leading)
                Text(album.displayArtist)
                    .font(.subheadline)
                    .foregroundStyle(TVDesignTokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
                    .frame(width: 220, alignment: .leading)
            }
            .frame(width: 220)
            .clipped()
        }
        .buttonStyle(TVCinematicCardStyle())
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
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
                    .frame(width: 220, alignment: .leading)
            }
            .frame(width: 220)
            .clipped()
        }
        .buttonStyle(TVCinematicCardStyle())
    }
}

/// Async artwork loader with a placeholder → fade-in, fetching against
/// `RemoteAPIClient.artworkURL(artworkId:)` (which already embeds the `?token=` query item — see
/// that method's doc comment). TV-local rather than shared: the iOS artwork loader
/// (`RemoteArtworkImageLoader`) is entangled with iOS's on-disk image cache, which isn't a clean
/// fit for the OS-purgeable `Caches` story tvOS uses (see `progress/tvos-playback.md`).
///
/// Deliberately NOT built on bare `AsyncImage` — root-caused a "no artwork on the FIRST Now
/// Playing open, but a re-open shows it" bug (`progress/tvos-relay-reception.md` 追記): `AsyncImage`
/// starts its fetch from its own internal `onAppear`, and when it's newly inserted as part of a
/// `.fullScreenCover` presentation TRANSITION (not a plain appear), that internal `onAppear` can
/// fire and its request get raced/dropped by the transition without `AsyncImage` ever retrying —
/// it only reacts to an explicit URL change, and the URL here doesn't change once
/// `player.currentSong` is set. A second open constructs a brand-new `TVNowPlayingView`/
/// `TVArtworkImage` outside any transition, so it loads cleanly and the bug reads as "works after
/// reopen". Driving the fetch from `.task(id:)` instead sidesteps this: SwiftUI's task lifecycle
/// is scheduled independently of the presentation transition's appear/disappear timing and is
/// guaranteed to run once per `artworkId`, so the image now reliably appears on the first open too
/// (placeholder → fade-in once loaded).
struct TVArtworkImage: View {
    let artworkId: String
    let client: RemoteAPIClient

    @State private var loadedImage: UIImage?
    @State private var loadedArtworkId: String?

    var body: some View {
        ZStack {
            if let loadedImage, loadedArtworkId == artworkId {
                Image(uiImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.secondary.opacity(0.2))
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(TVDesignTokens.textSecondary)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: loadedArtworkId)
        .task(id: artworkId) { await load() }
    }

    private func load() async {
        guard !artworkId.isEmpty, let url = URL(string: client.artworkURL(artworkId: artworkId)) else {
            loadedImage = nil
            loadedArtworkId = nil
            return
        }
        guard let (data, _) = try? await RemoteLANURLSession.shared.data(from: url) else { return }
        guard let image = UIImage(data: data) else { return }
        guard !Task.isCancelled else { return }
        loadedImage = image
        loadedArtworkId = artworkId
    }
}

/// Shelf card for the Phase 3-3 relay entry — thumbnail loaded directly from the YouTube CDN URL
/// the host reports (public internet, no LAN auth needed), not through `TVArtworkImage`/
/// `RemoteAPIClient.artworkURL` since this isn't a library artwork id.
private struct TVRelayCard: View {
    let title: String
    let thumbnailURLString: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                AsyncImage(url: URL(string: thumbnailURLString)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(.secondary.opacity(0.2))
                            Image(systemName: "play.tv")
                                .font(.system(size: 40))
                                .foregroundStyle(TVDesignTokens.textSecondary)
                        }
                    }
                }
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .clipped()
                Text(title.isEmpty ? String(localized: "tv.browse.relay") : title)
                    .font(.headline)
                    .lineLimit(1)
            }
            .frame(width: 220)
        }
        .buttonStyle(TVCinematicCardStyle())
    }
}

/// Broadcast-type banner shown while relay playback is active. Per the plan the PC (Host) is the
/// operator, so this still has no seek/skip controls (the desktop has no embed queue to skip
/// within — `progress/tvos-relay-reception.md` 追記), but it now sends play/pause and stop over
/// `POST /v1/remote/command` (`toggle`/`stop`) so the TV isn't a dead end while relaying: selecting
/// back/menu on the Siri Remote (or the exit button) dismisses this `fullScreenCover`, which
/// triggers `onDisappear` and stops the stream reception locally.
///
/// Also renders the failure-recovery state (`TVRelayPlaybackController.state == .failed`, see
/// `progress/tvos-relay-reception.md`): by the time this case renders, the controller has already
/// torn the `AVPlayer` down and local playback is usable again — this view only needs to surface
/// the localised error and let the user exit.
private struct TVRelayBannerView: View {
    @ObservedObject var relayModel: TVRelayModel
    @ObservedObject var relayPlaybackController: TVRelayPlaybackController
    let client: RemoteAPIClient
    let onExit: () -> Void

    var body: some View {
        Group {
            switch relayPlaybackController.state {
            case .failed(let reason):
                failureContent(reason: reason)
            case .idle, .playing:
                playingContent
            }
        }
        .padding(64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVDesignTokens.charcoalBase)
        .onDisappear { relayPlaybackController.stop() }
        // Siri Remote's physical play/pause button while this screen is frontmost — mirrors the
        // on-screen toggle button below rather than driving any TV-local player (there is none;
        // the audio is the host's own YouTube embed).
        .onPlayPauseCommand { Task { await sendToggle() } }
    }

    private var playingContent: some View {
        VStack(spacing: 32) {
            relayThumbnailCard
            Text(String(localized: "tv.relay.banner.subtitle"))
                .font(.headline)
                .foregroundStyle(TVDesignTokens.textSecondary)
            Text(relayModel.title)
                .font(.title)
                .multilineTextAlignment(.center)
            if relayModel.position.isSeekable {
                TVRelaySeekBar(position: relayModel.position, onSeek: { relayModel.seek(to: $0) })
                    .frame(maxWidth: 720)
            }
            transportRow
            Button(String(localized: "tv.relay.banner.exit"), action: onExit)
        }
    }

    /// Large 16:9 artwork treatment for the relay Now Playing (coordinator-added scope: "show the
    /// thumbnail as beautifully as possible" since there is no video on TV). YouTube thumbnails
    /// are natively 16:9 — unlike the square local-song artwork elsewhere in the app, this must
    /// never be centre-cropped into a square frame. A blurred, heavily-scaled copy of the same
    /// image fills the card behind it (matching the cinematic language used for local Now
    /// Playing's ambient background) so letterboxing never shows flat colour, and the sharp image
    /// fades in once loaded rather than popping in abruptly.
    private var relayThumbnailCard: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, 960)
            let height = width * 9 / 16
            ZStack {
                AsyncImage(url: URL(string: relayModel.thumbnail)) { phase in
                    if case .success(let image) = phase {
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 40)
                            .opacity(0.6)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 24))

                AsyncImage(url: URL(string: relayModel.thumbnail)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .transition(.opacity.animation(.easeIn(duration: 0.35)))
                    case .empty:
                        Color.clear
                    default:
                        Image(systemName: "play.tv")
                            .font(.system(size: 96))
                            .foregroundStyle(TVDesignTokens.textSecondary)
                    }
                }
                .frame(width: width, height: height)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: TVDesignTokens.signaturePink.opacity(0.25), radius: 36)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 400)
    }

    private var transportRow: some View {
        HStack(spacing: 56) {
            Button {
                relayModel.seek(to: relayModel.position.seekTarget(delta: -10))
            } label: {
                Image(systemName: "gobackward.10")
            }
            .buttonStyle(TVTransportButtonStyle(size: 32))
            .accessibilityLabel(String(localized: "tv.relay.transport.seekBack"))
            .opacity(relayModel.position.isSeekable ? 1 : 0)
            .disabled(!relayModel.position.isSeekable)

            Button {
                Task { await sendToggle() }
            } label: {
                Image(systemName: relayModel.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(TVTransportButtonStyle(size: 40))
            .accessibilityLabel(String(localized: relayModel.isPlaying ? "tv.relay.transport.pause" : "tv.relay.transport.play"))

            Button {
                Task { await sendStop() }
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(TVTransportButtonStyle(size: 40))
            .accessibilityLabel(String(localized: "tv.relay.transport.stop"))

            Button {
                relayModel.seek(to: relayModel.position.seekTarget(delta: 10))
            } label: {
                Image(systemName: "goforward.10")
            }
            .buttonStyle(TVTransportButtonStyle(size: 32))
            .accessibilityLabel(String(localized: "tv.relay.transport.seekForward"))
            .opacity(relayModel.position.isSeekable ? 1 : 0)
            .disabled(!relayModel.position.isSeekable)
        }
    }

    /// `POST /v1/remote/command` (`action: "toggle"`) — whether the desktop honours this during
    /// embed playback is the parallel desktop-side fix; this view's job is only to send the
    /// correct command and reflect `TVRelayModel.isPlaying` from the next `/v1/remote/state` poll.
    private func sendToggle() async {
        _ = try? await client.sendCommand(action: "toggle", value: nil)
    }

    /// `POST /v1/remote/command` (`action: "stop"`), then tears down the TV-side relay reception
    /// via the existing exit path (`onExit` → dismiss → `onDisappear` → `relayPlaybackController.stop()`).
    private func sendStop() async {
        _ = try? await client.sendCommand(action: "stop", value: nil)
        onExit()
    }

    private func failureContent(reason: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.yellow)
            Text(String(localized: "tv.relay.error.title"))
                .font(.title2)
            Text(reason)
                .font(.body)
                .foregroundStyle(TVDesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "tv.relay.banner.exit"), action: onExit)
        }
    }
}

/// Seek bar for the relay banner (Task B, `progress/tvos-relay-reception.md`). tvOS idiom: the bar
/// is a focusable element; while focused, left/right on the Siri Remote's touch surface (delivered
/// as `onMoveCommand`) nudges the position ±10s per press, and press-and-hold auto-repeats via the
/// same command (the system already debounces/repeats directional presses while held, so no manual
/// timer is needed here). Position updates optimistically (`TVRelayModel.seek(to:)`) — the actual
/// audio jump arrives ~1s later once the host's embed seeks and the relay jitter buffer refills.
private struct TVRelaySeekBar: View {
    let position: TVRelayPositionState
    let onSeek: (Double) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: isFocused ? 10 : 6)
                    Capsule()
                        .fill(TVDesignTokens.signatureAngularGradient)
                        .frame(width: max(proxy.size.width * position.fraction, 4), height: isFocused ? 10 : 6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 10)
            .focusable(true)
            .focused($isFocused)
            .scaleEffect(isFocused ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    onSeek(position.seekTarget(delta: -10))
                case .right:
                    onSeek(position.seekTarget(delta: 10))
                default:
                    break
                }
            }

            HStack {
                Text(Self.formatted(position.position))
                Spacer()
                Text(Self.formatted(position.duration))
            }
            .font(.caption)
            .foregroundStyle(TVDesignTokens.textSecondary)
        }
    }

    private static func formatted(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Shown while the "PC経由で再生中" flow (`TVRemotePlaySongCoordinator`) is sending `play-song` and
/// waiting for the host's relay to come up. On success `TVBrowseView` swaps this cover for
/// `TVRelayBannerView` (`onChange(of: remotePlaySongCoordinator.state)`); on failure/timeout this
/// same view shows the localised error with an exit button, matching `TVRelayBannerView`'s
/// failure-recovery presentation.
private struct TVRemotePlaySongWaitingView: View {
    @ObservedObject var coordinator: TVRemotePlaySongCoordinator
    let onExit: () -> Void

    var body: some View {
        Group {
            switch coordinator.state {
            case .failed(let reason):
                failureContent(reason: reason)
            case .idle, .sending, .waitingForRelay, .active:
                waitingContent
            }
        }
        .padding(64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TVDesignTokens.charcoalBase)
    }

    private var waitingContent: some View {
        VStack(spacing: 32) {
            ProgressView()
                .controlSize(.large)
            Text(String(localized: "tv.remotePlay.waiting.subtitle"))
                .font(.headline)
                .foregroundStyle(TVDesignTokens.textSecondary)
            Button(String(localized: "tv.relay.banner.exit"), action: onExit)
        }
    }

    private func failureContent(reason: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.yellow)
            Text(String(localized: "tv.remotePlay.error.title"))
                .font(.title2)
            Text(reason)
                .font(.body)
                .foregroundStyle(TVDesignTokens.textSecondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "tv.relay.banner.exit"), action: onExit)
        }
    }
}

#if DEBUG
/// Preview-only harness for `UXTV_PREVIEW=browse` (see `UXMusicTVApp`), rendering the shelf layout
/// with stub albums/playlists directly — bypassing `TVBrowseModel`'s network load — so the
/// cinematic focus treatment (`TVCinematicCardStyle`) can be screenshotted without pairing. See
/// `progress/tvos-design.md`.
struct TVBrowsePreviewHarness: View {
    private let client = RemoteAPIClient(baseURLString: "http://198.51.100.1:9999")

    private static let albums: [Album] = (1 ... 4).map { i in
        Album(
            normalisedAlbumTitle: "デモアルバム \(i)",
            artistName: "UX Music Demo",
            artworkId: "preview-\(i)",
            songs: [Song(id: "song-\(i)", path: "", title: "デモ曲 \(i)", artist: "UX Music Demo")]
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 48) {
                    TVBrowseHeader()
                    TVShelfSection(title: String(localized: "tv.browse.albums")) {
                        ForEach(Self.albums) { album in
                            TVAlbumCard(album: album, client: client) {}
                        }
                    }
                }
                .padding(.horizontal, 64)
                .padding(.vertical, 32)
            }
            .navigationTitle("")
        }
        .background(TVCinematicBackground(intensity: 0.6))
    }
}
#endif

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
                .foregroundStyle(TVDesignTokens.textSecondary)
            Button(String(localized: "tv.browse.error.retry"), action: onRetry)
        }
        .padding()
    }
}
