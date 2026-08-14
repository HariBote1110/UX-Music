import SwiftUI

/// Fullscreen "sidecar" now-playing display, pushed by the paired Mac (`sidecar.active` in
/// `/v1/remote/state`, parsed by `SidecarDirective`). Display-only — playback stays on the
/// desktop; `AppModel`'s sidecar poller keeps `sidecarTitle`/`sidecarPosition`/… fresh while this
/// screen is presented. Landscape-first (the screen forces landscape while presented — see
/// `SidecarOrientationPolicy`): large artwork on the leading side, synced lyrics on the trailing
/// side, a thin progress bar along the bottom. The close button and time labels fade out after a
/// few seconds of inactivity for an "idle elegance" ambient look (`SidecarChromeVisibilityPolicy`);
/// any tap brings them back.
struct SidecarScreen: View {
    @Environment(AppModel.self) private var model
    @State private var lyricsLines: [LRCParser.TimedLine] = []
    @State private var lyricsPlainText: String?
    @State private var lyricsLoadedForSongId: String?
    @State private var lastInteraction = Date()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NowPlayingAmbientBackground(palette: nil)
                .ignoresSafeArea(.all)

            // Darkening scrim so artwork/lyrics text always keeps contrast regardless of the
            // ambient background's derived palette.
            LinearGradient(
                colors: [Color.black.opacity(0.45), Color.black.opacity(0.2), Color.black.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(.all)

            GeometryReader { geo in
                let isLandscape = geo.size.width > geo.size.height
                Group {
                    if isLandscape {
                        HStack(alignment: .center, spacing: 40) {
                            artworkAndInfo
                                .frame(maxWidth: geo.size.width * 0.4)
                            lyricsPane
                        }
                    } else {
                        VStack(spacing: 24) {
                            artworkAndInfo
                            lyricsPane
                        }
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            VStack {
                Spacer()
                progressBar
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)
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
            .opacity(chromeVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.4), value: chromeVisible)
        }
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .onTapGesture { lastInteraction = Date() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            applyOrientation(sidecarPresented: true)
            lastInteraction = Date()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            applyOrientation(sidecarPresented: false)
        }
        .task(id: model.sidecarSongId) {
            await reloadLyricsIfNeeded()
        }
    }

    // MARK: - Idle chrome visibility

    /// `TimelineView` isn't available for a plain computed property, so this samples "now" only via
    /// `progressBar`/`lyricsPane`'s own periodic ticks; the close button reuses the same
    /// `lastInteraction` state and re-renders whenever a tap updates it or the periodic tick below
    /// forces a body re-evaluation.
    private var chromeVisible: Bool {
        SidecarChromeVisibilityPolicy.isVisible(lastInteraction: lastInteraction, now: chromeNow)
    }

    @State private var chromeNow = Date()

    // MARK: - Orientation

    /// Forces landscape while this screen is on screen, restoring the app's normal `.all` mask on
    /// dismiss (see `SidecarOrientationPolicy`, `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`).
    private func applyOrientation(sidecarPresented: Bool) {
        SidecarOrientationLock.current = SidecarOrientationPolicy.mask(sidecarPresented: sidecarPresented)
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }
        if sidecarPresented {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        } else {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .all)) { _ in }
        }
        scene.windows.first(where: \.isKeyWindow)?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    // MARK: - Artwork + track info

    private var artworkAndInfo: some View {
        VStack(spacing: 20) {
            SidecarArtworkView(songId: model.sidecarSongId, artworkId: model.sidecarArtworkId, title: model.sidecarTitle, artist: model.sidecarArtist)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 420)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.6), radius: 36, y: 20)
                .padding(.horizontal, 12)

            VStack(spacing: 6) {
                Text(model.sidecarTitle.isEmpty ? String(localized: "No track") : model.sidecarTitle)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Text(model.sidecarArtist)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                if !model.sidecarAlbum.isEmpty {
                    Text(model.sidecarAlbum)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
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
            VStack(spacing: 14) {
                Image(systemName: "music.note")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.22))
                Text(String(localized: "No Lyrics"))
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            let labelsVisible = SidecarChromeVisibilityPolicy.isVisible(lastInteraction: lastInteraction, now: context.date)
            VStack(spacing: 8) {
                GeometryReader { geo in
                    let fraction = model.sidecarDuration > 0 ? min(1, max(0, interpolated / model.sidecarDuration)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(.white.opacity(0.7))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 3)

                HStack {
                    Text(sidecarFormatTime(interpolated))
                    Spacer()
                    Text(sidecarFormatTime(max(0, model.sidecarDuration - interpolated)))
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .opacity(labelsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: labelsVisible)
            }
            .onChange(of: context.date) { _, newDate in
                chromeNow = newDate
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
/// rather than duplicating the motion system for a secondary, glanceable display). The active line
/// is full-opacity/larger/bold; neighbouring lines dim further the more lines away from active they
/// are, so the eye is drawn to the current lyric without the rest of the pane feeling empty.
private struct SidecarSyncedLyricsList: View {
    @Environment(AppModel.self) private var model
    let lines: [LRCParser.TimedLine]

    /// Updated at most once per actual line change (see `SidecarActiveLineUpdatePolicy`) rather
    /// than on every 0.2s tick, so the `ForEach` below only re-diffs when the highlighted line
    /// genuinely moves instead of 5x/sec for as long as the sidecar screen is on screen.
    @State private var activeIndex = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let distance = abs(index - activeIndex)
                        let isActive = index == activeIndex
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: isActive ? 23 : 18, weight: isActive ? .bold : .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(SidecarSyncedLyricsList.opacity(forDistance: distance, isActive: isActive)))
                            .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            .onChange(of: activeIndex) { _, newValue in
                guard lines.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo(lines[newValue].id, anchor: .center)
                }
            }
            .background(
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    Color.clear
                        .task(id: context.date) {
                            let interpolated = SidecarProgressInterpolation.interpolatedPosition(
                                position: model.sidecarPosition,
                                timestamp: model.sidecarPositionTimestamp,
                                playing: model.sidecarPlaying,
                                now: context.date,
                                duration: model.sidecarDuration
                            )
                            let newActive = LRCParser.activeLineIndex(in: lines, at: interpolated)
                            if SidecarActiveLineUpdatePolicy.shouldUpdate(currentIndex: activeIndex, newIndex: newActive) {
                                activeIndex = newActive
                            }
                        }
                }
            )
        }
    }

    /// Distance-based opacity falloff for non-active lines: the active line is fully opaque, and
    /// each further line away dims a bit more, bottoming out at a low but still legible floor.
    private static func opacity(forDistance distance: Int, isActive: Bool) -> Double {
        guard !isActive else { return 1 }
        return max(0.2, 0.55 - Double(distance) * 0.08)
    }
}
