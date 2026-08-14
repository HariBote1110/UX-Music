import SwiftUI

/// Fullscreen "sidecar" now-playing display, pushed by the paired Mac (`sidecar.active` in
/// `/v1/remote/state`, parsed by `SidecarDirective`). Display-only — playback stays on the
/// desktop; `AppModel`'s sidecar poller keeps `sidecarTitle`/`sidecarPosition`/… fresh while this
/// screen is presented. Landscape-friendly: large artwork on the leading side, synced lyrics on
/// the trailing side, a thin progress bar along the bottom.
struct SidecarScreen: View {
    @Environment(AppModel.self) private var model
    @State private var lyricsLines: [LRCParser.TimedLine] = []
    @State private var lyricsPlainText: String?
    @State private var lyricsLoadedForSongId: String?
    @State private var showControls = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NowPlayingAmbientBackground(palette: nil)
                .ignoresSafeArea(.all)

            Color.black.opacity(0.25)
                .ignoresSafeArea(.all)

            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height
                Group {
                    if isLandscape {
                        HStack(alignment: .center, spacing: 32) {
                            artworkAndInfo
                                .frame(maxWidth: geo.size.width * 0.42)
                            lyricsPane
                        }
                    } else {
                        VStack(spacing: 20) {
                            artworkAndInfo
                            lyricsPane
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack {
                Spacer()
                progressBar
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }

            NowPlayingNavIconButton(
                action: { model.dismissSidecarLocally() },
                accessibilityLabel: String(localized: "Close")
            ) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .opacity(showControls ? 1 : 0.35)
        }
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task(id: model.sidecarSongId) {
            await reloadLyricsIfNeeded()
        }
    }

    // MARK: - Artwork + track info

    private var artworkAndInfo: some View {
        VStack(spacing: 18) {
            SidecarArtworkView(songId: model.sidecarSongId, artworkId: model.sidecarArtworkId, title: model.sidecarTitle, artist: model.sidecarArtist)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.55), radius: 32, y: 18)

            VStack(spacing: 8) {
                Text(model.sidecarTitle.isEmpty ? String(localized: "No track") : model.sidecarTitle)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(model.sidecarArtist)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Lyrics

    @ViewBuilder
    private var lyricsPane: some View {
        if !lyricsLines.isEmpty {
            SidecarSyncedLyricsList(lines: lyricsLines)
        } else if let plain = lyricsPlainText, !plain.isEmpty {
            ScrollView {
                Text(plain)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
        } else {
            ContentUnavailableView {
                Label(String(localized: "No Lyrics"), systemImage: "text.page")
            }
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func reloadLyricsIfNeeded() async {
        guard let songId = model.sidecarSongId, !songId.isEmpty, lyricsLoadedForSongId != songId else {
            if model.sidecarSongId == nil {
                lyricsLines = []
                lyricsPlainText = nil
                lyricsLoadedForSongId = nil
            }
            return
        }
        lyricsLoadedForSongId = songId
        lyricsLines = []
        lyricsPlainText = nil
        do {
            let payload = try await model.withFailover { try await $0.fetchLyrics(songId: songId) }
            guard payload.found, let content = payload.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                return
            }
            if payload.type == "lrc" {
                let timed = LRCParser.parseTimedLines(content)
                if !timed.isEmpty {
                    lyricsLines = timed
                    return
                }
            }
            lyricsPlainText = content
        } catch {
            // Lyrics are optional for the sidecar display; leave the "No Lyrics" placeholder.
        }
    }

    // MARK: - Progress

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let interpolated = SidecarProgressInterpolation.interpolatedPosition(
                position: model.sidecarPosition,
                timestamp: model.sidecarPositionTimestamp,
                playing: model.sidecarPlaying,
                now: context.date,
                duration: model.sidecarDuration
            )
            VStack(spacing: 6) {
                GeometryReader { geo in
                    let fraction = model.sidecarDuration > 0 ? min(1, max(0, interpolated / model.sidecarDuration)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(.white.opacity(0.85))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 4)

                HStack {
                    Text(sidecarFormatTime(interpolated))
                    Spacer()
                    Text(sidecarFormatTime(model.sidecarDuration))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private func sidecarFormatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let m = Int(seconds) / 60
    let s = Int(seconds) % 60
    return "\(m):\(String(format: "%02d", s))"
}

/// Resolves the sidecar's artwork: uses `artworkId` directly when the directive supplied one,
/// otherwise falls back to fuzzy title/artist matching against the Remote library — mirroring
/// `RemoteControlScreen.RemoteArtworkCard`, which has no `artworkId` in `/v1/remote/state` to work with.
private struct SidecarArtworkView: View {
    @Environment(AppModel.self) private var model
    let songId: String?
    let artworkId: String?
    let title: String
    let artist: String

    private var resolvedArtworkId: String? {
        if let artworkId, !artworkId.isEmpty { return artworkId }
        guard case .loaded(let songs) = model.libraryState else { return nil }
        if let songId, !songId.isEmpty, let matched = songs.first(where: { $0.id == songId }), !matched.artworkId.isEmpty {
            return matched.artworkId
        }
        guard !title.isEmpty else { return nil }
        let matched = songs.first { $0.title == title && $0.artist == artist } ?? songs.first { $0.title == title }
        guard let matched, !matched.artworkId.isEmpty else { return nil }
        return matched.artworkId
    }

    var body: some View {
        Group {
            if let id = resolvedArtworkId {
                ArtworkImageView(artworkId: id, urlString: model.artworkURL(for: id), cornerRadius: 0, size: nil)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(white: 0.14), Color(white: 0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "hifispeaker.2.fill")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.28))
                }
            }
        }
        .task {
            if case .idle = model.libraryState {
                await model.refreshLibrary()
            }
        }
    }
}

/// Simple synced-lyrics list for the sidecar (a plain scrolling highlight, not the full cascade
/// motion `NowPlayingSyncedLyricsScroll` uses — that type is private to
/// `NowPlayingLyricsScreen.swift`, so this reuses its underlying `LRCParser` data/active-line logic
/// rather than duplicating the motion system for a secondary, glanceable display).
private struct SidecarSyncedLyricsList: View {
    @Environment(AppModel.self) private var model
    let lines: [LRCParser.TimedLine]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let interpolated = SidecarProgressInterpolation.interpolatedPosition(
                position: model.sidecarPosition,
                timestamp: model.sidecarPositionTimestamp,
                playing: model.sidecarPlaying,
                now: context.date,
                duration: model.sidecarDuration
            )
            let active = LRCParser.activeLineIndex(in: lines, at: interpolated)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: line.id == lines[active].id ? 22 : 18, weight: line.id == lines[active].id ? .bold : .regular, design: .rounded))
                                .foregroundStyle(line.id == lines[active].id ? .white : .white.opacity(0.45))
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
                }
                .onChange(of: active) { _, newValue in
                    guard lines.indices.contains(newValue) else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lines[newValue].id, anchor: .center)
                    }
                }
            }
        }
    }
}
