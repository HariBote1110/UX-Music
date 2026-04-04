import SwiftUI

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

                NowPlayingArtworkBlock(urlString: artworkURLString, accent: accent)
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
    let urlString: String
    let accent: Color

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
    }

    @ViewBuilder
    private var artworkFill: some View {
        if urlString.isEmpty {
            placeholder
        } else if let u = URL(string: urlString) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    placeholder
                case .empty:
                    ZStack {
                        placeholder
                        ProgressView()
                            .tint(.white.opacity(0.6))
                    }
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
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

    private static func equaliserBandLabel(for index: Int) -> String {
        let hz = GraphicEqualiserConfiguration.centreFrequenciesHz[index]
        if hz >= 1000 {
            let k = hz / 1000
            return k.rounded() == k ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz))"
    }

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
                    ForEach(0 ..< GraphicEqualiserConfiguration.bandCount, id: \.self) { index in
                        HStack(spacing: 10) {
                            Text(Self.equaliserBandLabel(for: index))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .leading)
                            Slider(
                                value: Binding(
                                    get: { Double(model.player.equaliserBandDecibels[index]) },
                                    set: { model.player.setEqualiserBand(index: index, decibels: Float($0)) }
                                ),
                                in: -24 ... 24
                            )
                            .disabled(!model.player.equaliserEnabled)
                            Text("\(Int(model.player.equaliserBandDecibels[index]))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 32, alignment: .trailing)
                        }
                    }
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

private func swipeHint(_ text: String) -> some View {
    Text(text)
        .font(.caption2)
        .foregroundStyle(.tertiary)
}
