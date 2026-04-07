import SwiftUI
import UIKit

private let nowPlayingFallbackAccent = Color(red: 0.45, green: 0.82, blue: 1.0)

private enum NowPlayingPage: Equatable {
    case main
    case queue
    case favourites
    case playbackSettings
}

private enum StripDragAxis {
    case horizontal
    case vertical
}

private let nowPlayingPanelSpring = Animation.spring(response: 0.52, dampingFraction: 0.78, blendDuration: 0.12)

private func stripBaseX(page: NowPlayingPage, width w: CGFloat) -> CGFloat {
    switch page {
    case .main: return -w
    case .favourites: return 0
    case .queue: return -2 * w
    case .playbackSettings: return -w
    }
}

/// Rubber-band slightly past [-2w, 0] for a softer feel while dragging.
private func displayStripOffset(page: NowPlayingPage, horizontalDrag: CGFloat, width w: CGFloat) -> CGFloat {
    guard w > 1 else { return 0 }
    guard page != .playbackSettings else { return -w }
    let base = stripBaseX(page: page, width: w)
    var raw = base + horizontalDrag
    let minX = -2 * w
    let maxX: CGFloat = 0
    if raw < minX {
        let over = raw - minX
        raw = minX + over * 0.35
    } else if raw > maxX {
        let over = raw - maxX
        raw = maxX + over * 0.45
    }
    return raw
}

/// `ToolbarItem` can propose a short height; large frames get clipped and `Circle()` looks truncated.
private struct NowPlayingNavIconButton<Content: View>: View {
    let action: () -> Void
    let accessibilityLabel: String
    @ViewBuilder var label: () -> Content

    private let diameter: CGFloat = 34

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                label()
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var page: NowPlayingPage = .main
    @State private var horizontalDrag: CGFloat = 0
    @State private var lockedDragAxis: StripDragAxis?
    @State private var showLyricsScreen = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                ZStack(alignment: .top) {
                    HStack(spacing: 0) {
                        NowPlayingFavouritesPanel(page: $page)
                            .frame(width: w, height: h)
                        Group {
                            if let song = model.player.currentSong {
                                NowPlayingPlayingShell(
                                    song: song,
                                    artworkId: song.artworkId,
                                    artworkURLString: model.artworkURL(for: song.artworkId)
                                )
                            } else {
                                NowPlayingEmptyChrome()
                            }
                        }
                        .frame(width: w, height: h)
                        NowPlayingQueuePanel(page: $page)
                            .frame(width: w, height: h)
                    }
                    .frame(width: 3 * w, height: h, alignment: .leading)
                    .offset(
                        x: displayStripOffset(page: page, horizontalDrag: horizontalDrag, width: w)
                            + (page == .playbackSettings ? -3 * w : 0)
                    )
                    .frame(width: w, height: h, alignment: .leading)
                    .clipped()
                    .allowsHitTesting(page != .playbackSettings)
                    .gesture(stripDragGesture(width: w, height: h))

                    if page == .playbackSettings {
                        NowPlayingPlaybackSettingsPanel(page: $page)
                            .frame(width: w, height: h)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(1)
                    }
                }
                .frame(width: w, height: h)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if page == .main {
                        NowPlayingNavIconButton(action: { dismiss() }, accessibilityLabel: "Close") {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    } else {
                        NowPlayingNavIconButton(action: {
                            withAnimation(nowPlayingPanelSpring) {
                                page = .main
                                horizontalDrag = 0
                            }
                        }, accessibilityLabel: "Back to player") {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if page == .main, let song = model.player.currentSong {
                        HStack(spacing: 10) {
                            NowPlayingNavIconButton(action: {
                                showLyricsScreen = true
                            }, accessibilityLabel: "歌詞を表示") {
                                Image(systemName: "text.alignleft")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(
                                        model.hasLocalLyricsFile(for: song.id)
                                            ? Color.white.opacity(0.9)
                                            : Color.white.opacity(0.38)
                                    )
                            }
                            NowPlayingNavIconButton(action: {
                                model.toggleFavourite(songId: song.id)
                            }, accessibilityLabel: "Favourite") {
                                Image(systemName: model.isFavouriteSong(songId: song.id) ? "heart.fill" : "heart")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(model.isFavouriteSong(songId: song.id) ? Color.pink : Color.white.opacity(0.85))
                            }
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(page == .favourites || page == .queue)
        .fullScreenCover(isPresented: $showLyricsScreen) {
            if let song = model.player.currentSong {
                NowPlayingLyricsScreen(song: song, isPresented: $showLyricsScreen)
                    .environment(model)
            }
        }
        .onAppear {
            horizontalDrag = 0
            lockedDragAxis = nil
        }
    }

    private func setHorizontalDragLive(_ value: CGFloat) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            horizontalDrag = value
        }
    }

    private func stripDragGesture(width w: CGFloat, height h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                guard page != .playbackSettings, w > 1, h > 1 else { return }
                let tx = value.translation.width
                let ty = value.translation.height
                let startY = value.startLocation.y

                if lockedDragAxis == nil {
                    let dist = hypot(tx, ty)
                    guard dist > 10 else { return }
                    switch page {
                    case .main:
                        // Artwork + title/metadata sit below the top half; only reserve the bottom band
                        // (transport + scrubber) for vertical-only drags so pull-down dismiss still wins there.
                        let horizontalStripFriendlyTopFraction: CGFloat = 0.82
                        if abs(tx) >= abs(ty) {
                            lockedDragAxis = startY < h * horizontalStripFriendlyTopFraction ? .horizontal : .vertical
                        } else {
                            lockedDragAxis = .vertical
                        }
                    case .favourites, .queue:
                        // Horizontal strip only: vertical motion is for list scrolling / no sheet actions.
                        guard abs(tx) >= abs(ty) else { return }
                        lockedDragAxis = .horizontal
                    case .playbackSettings:
                        break
                    }
                }

                guard lockedDragAxis == .horizontal else { return }
                setHorizontalDragLive(tx)
            }
            .onEnded { value in
                handleStripDragEnded(translation: value.translation, width: w, height: h)
            }
    }

    private func handleStripDragEnded(translation: CGSize, width w: CGFloat, height h: CGFloat) {
        let tx = translation.width
        let ty = translation.height
        let axis = lockedDragAxis
        lockedDragAxis = nil

        guard page != .playbackSettings else {
            withAnimation(nowPlayingPanelSpring) {
                horizontalDrag = 0
            }
            return
        }

        guard let axis else {
            withAnimation(nowPlayingPanelSpring) {
                horizontalDrag = 0
            }
            return
        }

        if axis == .vertical {
            if page == .main {
                // Content scrolls down (finger moves up) → settings; content scrolls up (finger moves down) → album / dismiss.
                if ty < -52 {
                    withAnimation(nowPlayingPanelSpring) {
                        page = .playbackSettings
                        horizontalDrag = 0
                    }
                    return
                }
                if ty > 68 {
                    dismiss()
                    return
                }
            }
            withAnimation(nowPlayingPanelSpring) {
                horizontalDrag = 0
            }
            return
        }

        let thresholdTowardsSide: CGFloat = w * 0.14
        let thresholdBackToMain: CGFloat = w * 0.12
        switch page {
        case .main:
            if tx < -thresholdTowardsSide {
                withAnimation(nowPlayingPanelSpring) {
                    page = .queue
                    horizontalDrag = 0
                }
            } else if tx > thresholdTowardsSide {
                withAnimation(nowPlayingPanelSpring) {
                    page = .favourites
                    horizontalDrag = 0
                }
            } else {
                withAnimation(nowPlayingPanelSpring) {
                    horizontalDrag = 0
                }
            }
        case .queue:
            if tx > thresholdBackToMain {
                withAnimation(nowPlayingPanelSpring) {
                    page = .main
                    horizontalDrag = 0
                }
            } else {
                withAnimation(nowPlayingPanelSpring) {
                    horizontalDrag = 0
                }
            }
        case .favourites:
            if tx < -thresholdBackToMain {
                withAnimation(nowPlayingPanelSpring) {
                    page = .main
                    horizontalDrag = 0
                }
            } else {
                withAnimation(nowPlayingPanelSpring) {
                    horizontalDrag = 0
                }
            }
        case .playbackSettings:
            break
        }
    }
}

// MARK: - Playing shell (isolates high-frequency player updates in child views)

private struct NowPlayingPlayingShell: View {
    let song: Song
    let artworkId: String
    let artworkURLString: String

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var palette: ArtworkPlaybackPalette?

    private var accent: Color {
        palette?.accentColor ?? nowPlayingFallbackAccent
    }

    var body: some View {
        ZStack {
            NowPlayingAmbientBackground(palette: palette)
                .animation(.easeInOut(duration: 0.5), value: palette)

            VStack(spacing: 0) {
                Spacer(minLength: horizontalSizeClass == .regular ? 40 : 16)

                NowPlayingArtworkBlock(artworkId: artworkId, urlString: artworkURLString, accent: accent)
                    .padding(.horizontal, 28)

                Spacer(minLength: 28)

                VStack(spacing: 10) {
                    Text(song.displayTitle)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(.white)

                    Text(song.displayArtist)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)

                    if !song.album.isEmpty {
                        Text(song.displayAlbum)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())

                Spacer(minLength: 24)

                NowPlayingProgressSection(accent: accent)
                    .padding(.horizontal, 24)

                Spacer(minLength: 20)

                NowPlayingTransportSection(accent: accent)
                    .padding(.bottom, 8)

                Spacer(minLength: horizontalSizeClass == .regular ? 48 : 24)
            }
        }
        .task(id: artworkURLString) {
            guard let url = URL(string: artworkURLString), !artworkURLString.isEmpty else {
                palette = nil
                return
            }
            palette = await ArtworkPaletteExtractor.palette(forArtworkURL: url)
        }
    }
}

// MARK: - Progress (only this subtree observes position / duration)

private struct NowPlayingProgressSection: View {
    @Environment(AppModel.self) private var model
    let accent: Color

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        let duration = max(model.player.durationSeconds, 0.001)
        VStack(alignment: .leading, spacing: 10) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : model.player.positionSeconds },
                    set: { newValue in
                        scrubValue = newValue
                    }
                ),
                in: 0 ... duration,
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        scrubValue = model.player.positionSeconds
                    } else {
                        isScrubbing = false
                        Task { await model.player.seek(to: scrubValue) }
                    }
                }
            )
            .tint(accent)
            .controlSize(.small)

            HStack {
                Text(formatTime(isScrubbing ? scrubValue : model.player.positionSeconds))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let m = Int(safe) / 60
        let s = Int(safe) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

// MARK: - Transport (only this subtree observes isPlaying)

private struct NowPlayingTransportSection: View {
    @Environment(AppModel.self) private var model
    let accent: Color

    var body: some View {
        HStack(spacing: 44) {
            transportIconButton(systemName: "backward.fill", size: 22) {
                Task { await model.player.previous() }
            }
            .accessibilityLabel("Previous track")

            Button {
                model.player.togglePlayPause()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 80, height: 80)
                    .background(
                        Circle()
                            .fill(.white)
                            .shadow(color: accent.opacity(0.35), radius: 24, y: 10)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.player.isPlaying ? "Pause" : "Play")

            transportIconButton(systemName: "forward.fill", size: 22) {
                Task { await model.player.next() }
            }
            .accessibilityLabel("Next track")
        }
    }

    private func transportIconButton(systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Empty state

private struct NowPlayingEmptyChrome: View {
    var body: some View {
        ZStack {
            NowPlayingAmbientBackground(palette: nil)
            VStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
                    .symbolRenderingMode(.hierarchical)
                Text("Nothing playing")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Text("Start playback from your library.")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
    }
}

// MARK: - Background

private struct NowPlayingAmbientBackground: View {
    var palette: ArtworkPlaybackPalette?

    var body: some View {
        ZStack {
            if let p = palette {
                LinearGradient(
                    colors: [
                        p.topColor,
                        Color.black,
                        p.bottomColor,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [p.accentColor.opacity(0.32), .clear],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 340
                )
                .blendMode(.plusLighter)

                RadialGradient(
                    colors: [p.bottomColor.opacity(0.55), .clear],
                    center: .bottomLeading,
                    startRadius: 10,
                    endRadius: 300
                )
                .blendMode(.plusLighter)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.05, blue: 0.12),
                        Color.black,
                        Color(red: 0.04, green: 0.06, blue: 0.09),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [nowPlayingFallbackAccent.opacity(0.22), .clear],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 320
                )
                .blendMode(.plusLighter)

                RadialGradient(
                    colors: [Color.purple.opacity(0.12), .clear],
                    center: .bottomLeading,
                    startRadius: 10,
                    endRadius: 280
                )
                .blendMode(.plusLighter)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Artwork

private struct NowPlayingArtworkBlock: View {
    let artworkId: String
    let urlString: String
    let accent: Color

    @State private var loaded: UIImage?

    private var taskIdentity: String { "\(artworkId)\u{1E}\(urlString)\u{1E}np" }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 340)
            .overlay {
                artworkFill
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 32, y: 18)
            .shadow(color: accent.opacity(0.15), radius: 40, y: 12)
            .task(id: taskIdentity) {
                loaded = nil
                guard !urlString.isEmpty else { return }
                loaded = await WearRemoteArtworkImageLoader.loadUIImage(artworkId: artworkId, urlString: urlString)
            }
    }

    @ViewBuilder
    private var artworkFill: some View {
        if urlString.isEmpty {
            placeholder
        } else if let img = loaded {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                placeholder
                ProgressView()
                    .tint(.white.opacity(0.6))
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(white: 0.14),
                    Color(white: 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.22))
        }
    }
}

// MARK: - Swipe side panels (queue / favourites / settings mock)

private struct NowPlayingQueuePanel: View {
    @Binding var page: NowPlayingPage
    @Environment(AppModel.self) private var model

    private var queue: [Song] {
        model.player.playbackQueue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up next")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)
            List {
                if queue.isEmpty {
                    Text("The queue is empty.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(queue.indices), id: \.self) { idx in
                        let song = queue[idx]
                        Button {
                            Task {
                                await model.player.playQueueItem(at: idx)
                                withAnimation(nowPlayingPanelSpring) {
                                    page = .main
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                if idx == model.player.currentQueueIndex {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(nowPlayingFallbackAccent)
                                        .frame(width: 22)
                                } else {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 22)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.displayTitle)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(song.displayArtist)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .listRowBackground(Color(red: 0.07, green: 0.07, blue: 0.08))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            swipeHint("Swipe right for player")
                .padding(.bottom, 12)
        }
    }
}

private struct NowPlayingFavouritesPanel: View {
    @Binding var page: NowPlayingPage
    @Environment(AppModel.self) private var model

    private var songs: [Song] {
        model.favouriteSongsForPlayback()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Favourites")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)
            List {
                if songs.isEmpty {
                    Text("No favourites yet. Tap the heart on the player while a track is playing.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(songs) { song in
                        Button {
                            let list = model.favouriteSongsForPlayback()
                            Task {
                                await model.player.play(song, newQueue: list)
                                withAnimation(nowPlayingPanelSpring) {
                                    page = .main
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkImageView(
                                    artworkId: song.artworkId,
                                    urlString: model.artworkURL(for: song.artworkId),
                                    cornerRadius: 6,
                                    size: 44
                                )
                                .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.displayTitle)
                                        .font(.body.weight(.semibold))
                                    Text(song.displayArtist)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .listRowBackground(Color(red: 0.07, green: 0.07, blue: 0.08))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.removeFavourite(songId: song.id)
                            } label: {
                                Label("Remove", systemImage: "heart.slash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            swipeHint("Swipe left for player")
                .padding(.bottom, 12)
        }
    }
}

private struct NowPlayingPlaybackSettingsPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var page: NowPlayingPage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Playback")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 8)
            List {
                Section {
                    Toggle(
                        "Enable equaliser",
                        isOn: Binding(
                            get: { model.player.equaliserEnabled },
                            set: { model.player.setEqualiserEnabled($0) }
                        )
                    )
                    Menu {
                        ForEach(GraphicEqualiserConfiguration.presetNamesOrdered, id: \.self) { name in
                            Button(name) {
                                model.player.applyEqualiserPreset(named: name)
                            }
                        }
                    } label: {
                        HStack {
                            Text("Preset")
                            Spacer()
                            Text(model.player.equaliserPresetDisplayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Preamp")
                        Slider(
                            value: Binding(
                                get: { Double(model.player.equaliserPreampDecibels) },
                                set: { model.player.setEqualiserPreampDecibels(Float($0)) }
                            ),
                            in: -24 ... 24
                        )
                        .disabled(!model.player.equaliserEnabled)
                        Text("\(Int(model.player.equaliserPreampDecibels)) dB")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    GraphicEQView()
                        .listRowInsets(.init(top: 8, leading: 10, bottom: 8, trailing: 10))
                } header: {
                    Text("Equaliser")
                }

                Section {
                    Toggle("Crossfade", isOn: .constant(false))
                        .disabled(true)
                    Toggle("Normalise loudness (mock)", isOn: .constant(true))
                        .disabled(true)
                } header: {
                    Text("Other")
                }

                Section {
                    Text("More audio options will appear here in a future update.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            swipeHint("Swipe down for player")
                .padding(.bottom, 12)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    let t = value.translation
                    guard t.height > 48, abs(t.height) > abs(t.width) else { return }
                    withAnimation(nowPlayingPanelSpring) {
                        page = .main
                    }
                }
        )
    }
}

// MARK: - EQ Curve Canvas

/// Pure display of the 10-band EQ frequency response as a polyline.
/// Positions are computed from the actual canvas size, so there is no fixed-offset drift.
private struct EQCurveCanvas: View {
    let decibels: [Float]
    var showLabels: Bool = true

    var body: some View {
        Canvas { context, size in
            drawCurve(context: context, size: size)
        }
    }

    private func drawCurve(context: GraphicsContext, size: CGSize) {
        let count = decibels.count
        guard count > 1 else { return }

        let leftInset: CGFloat = showLabels ? 28 : 4
        let topInset: CGFloat = 4
        let bottomInset: CGFloat = showLabels ? 18 : 4
        let plotW = size.width - leftInset
        let plotH = size.height - topInset - bottomInset

        func bandX(_ i: Int) -> CGFloat {
            leftInset + CGFloat(i) / CGFloat(count - 1) * plotW
        }
        func dbY(_ db: Double) -> CGFloat {
            topInset + (1.0 - (db + 24.0) / 48.0) * plotH
        }

        let zeroDby = dbY(0)
        let pts = decibels.indices.map { CGPoint(x: bandX($0), y: dbY(Double(decibels[$0]))) }

        // Horizontal grid lines every 6 dB (0 dB is more prominent)
        let gridDbs = stride(from: -24.0, through: 24.0, by: 6.0)
        for db in gridDbs {
            let y = dbY(db)
            var grid = Path()
            grid.move(to: CGPoint(x: leftInset, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
            let isZero = db == 0
            context.stroke(
                grid,
                with: .color(.white.opacity(isZero ? 0.28 : 0.10)),
                lineWidth: isZero ? 0.75 : 0.5
            )
        }

        // dB scale labels every 6 dB
        if showLabels {
            for db in gridDbs {
                let label = db > 0 ? "+\(Int(db))" : "\(Int(db))"
                context.draw(
                    Text(label)
                        .font(.system(size: 9, weight: db == 0 ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(db == 0 ? 0.75 : 0.45)),
                    at: CGPoint(x: leftInset - 4, y: dbY(db)),
                    anchor: .trailing
                )
            }
        }

        // Fill between polyline and 0 dB baseline
        var fill = Path()
        fill.move(to: CGPoint(x: pts[0].x, y: zeroDby))
        fill.addLine(to: pts[0])
        for i in 1 ..< count { fill.addLine(to: pts[i]) }
        fill.addLine(to: CGPoint(x: pts[count - 1].x, y: zeroDby))
        fill.closeSubpath()
        context.fill(fill, with: .color(.white.opacity(0.07)))

        // Polyline
        var line = Path()
        line.move(to: pts[0])
        for i in 1 ..< count { line.addLine(to: pts[i]) }
        context.stroke(line, with: .color(.white.opacity(0.7)), lineWidth: 1.5)

        // Band dots
        for pt in pts {
            let r: CGFloat = 2.5
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                with: .color(.white.opacity(0.9))
            )
        }

        // Frequency labels
        if showLabels {
            let labelY = size.height - bottomInset + 4
            for i in 0 ..< count {
                context.draw(
                    Text(EQCurveCanvas.freqLabel(i))
                        .font(.system(size: 8).weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.4)),
                    at: CGPoint(x: bandX(i), y: labelY),
                    anchor: .top
                )
            }
        }
    }

    static func freqLabel(_ index: Int) -> String {
        let hz = GraphicEqualiserConfiguration.centreFrequenciesHz[index]
        if hz >= 1000 {
            let k = hz / 1000
            return k.rounded() == k ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz))"
    }
}

// MARK: - Graphic EQ

/// Read-only graph row. Tap to open the band-adjustment sheet.
private struct GraphicEQView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdjustment = false

    var body: some View {
        Button { showAdjustment = true } label: {
            EQCurveCanvas(decibels: model.player.equaliserBandDecibels)
                .frame(height: 360)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(6)
                }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showAdjustment) {
            EQAdjustmentSheet()
        }
    }
}

// MARK: - EQ Adjustment Sheet

private struct EQAdjustmentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private static let stepDb: Float = 1

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Live mini graph
                EQCurveCanvas(decibels: model.player.equaliserBandDecibels)
                    .frame(height: 192)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                Divider()

                // Band +/− controls
                HStack(spacing: 0) {
                    ForEach(0 ..< GraphicEqualiserConfiguration.bandCount, id: \.self) { i in
                        bandControl(index: i)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 20)

                Spacer()
            }
            .navigationTitle("Equaliser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Flat") { model.player.resetEqualiserToFlat() }
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func bandControl(index: Int) -> some View {
        let db = model.player.equaliserBandDecibels[index]
        let dbInt = Int(db)
        let enabled = model.player.equaliserEnabled

        VStack(spacing: 6) {
            RepeatButton(
                action: {
                    let current = model.player.equaliserBandDecibels[index]
                    model.player.setEqualiserBand(index: index, decibels: min(24, current + Self.stepDb))
                },
                isDisabled: {
                    model.player.equaliserBandDecibels[index] >= 24 || !model.player.equaliserEnabled
                }
            ) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        Color.accentColor.opacity(db >= 24 || !enabled ? 0.05 : 0.15),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }

            Text(dbInt >= 0 ? "+\(dbInt)" : "\(dbInt)")
                .font(.system(size: 11).monospacedDigit().weight(.medium))
                .foregroundStyle(dbInt == 0 ? .secondary : .primary)
                .frame(height: 16)

            Text(EQCurveCanvas.freqLabel(index))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 12)

            RepeatButton(
                action: {
                    let current = model.player.equaliserBandDecibels[index]
                    model.player.setEqualiserBand(index: index, decibels: max(-24, current - Self.stepDb))
                },
                isDisabled: {
                    model.player.equaliserBandDecibels[index] <= -24 || !model.player.equaliserEnabled
                }
            ) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        Color.accentColor.opacity(db <= -24 || !enabled ? 0.05 : 0.15),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Repeat Button

/// 押下直後に1回実行 → 0.4秒後に 0.08秒間隔で高速繰り返し。
/// - `action` / `isDisabled` はクロージャで毎回評価するため、
///   ビュー再構築前の古い値をキャプチャしてしまう stale closure 問題を回避。
private struct RepeatButton<Label: View>: View {
    let action: () -> Void
    let isDisabled: () -> Bool
    @ViewBuilder let label: () -> Label

    @State private var holdTimer: Timer?

    var body: some View {
        label()
            .contentShape(Rectangle())
            // onLongPressGesture の pressing: は押下開始/終了を確実に検知する
            .onLongPressGesture(
                minimumDuration: 60, // perform は事実上発火させない
                pressing: { isPressing in
                    if isPressing {
                        guard !isDisabled() else { return }
                        action()
                        // 0.4 秒後に高速繰り返し開始
                        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { timer in
                                guard !isDisabled() else {
                                    timer.invalidate()
                                    return
                                }
                                action()
                            }
                        }
                    } else {
                        holdTimer?.invalidate()
                        holdTimer = nil
                    }
                },
                perform: {}
            )
            .opacity(isDisabled() ? 0.35 : 1.0)
    }
}

// MARK: -

private func swipeHint(_ text: String) -> some View {
    Text(text)
        .font(.caption2)
        .foregroundStyle(.tertiary)
}
