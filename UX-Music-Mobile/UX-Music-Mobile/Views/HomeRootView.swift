import SwiftUI

/// Walkman Cross UI のルート。中央=再生を起点に、画面全体のスワイプで十字方向の各ペインへ遷移する。
/// 各ペインは `AppModel` の実データ・実再生へ配線される。
struct HomeRootView: View {
    @Environment(AppModel.self) private var model
    @State private var navigation = MusicNavigationState()
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            sceneBackground

            GeometryReader { proxy in
                ZStack {
                    ForEach(MusicPane.allCases, id: \.self) { pane in
                        let filtered = MusicSwipeResolver.filteredDragOffset(
                            horizontal: dragOffset.width,
                            vertical: dragOffset.height
                        )
                        let offset = CrossPlayerLayout.offset(
                            for: pane,
                            currentPane: navigation.currentPane,
                            containerWidth: proxy.size.width,
                            containerHeight: proxy.size.height,
                            dragX: filtered.x,
                            dragY: filtered.y
                        )

                        paneView(for: pane, size: proxy.size)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .offset(x: offset.x, y: offset.y)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(swipeGesture)
                .clipped()
            }
            .ignoresSafeArea()

            bottomNowPlayingBar
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Background

    @ViewBuilder
    private var sceneBackground: some View {
        if navigation.currentPane == .player {
            PlayerGradientBackground()
        } else {
            Color(red: 0.00, green: 0.01, blue: 0.04)
                .ignoresSafeArea()
        }
    }

    // MARK: - Swipe

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                if let direction = MusicSwipeResolver.direction(
                    forHorizontal: value.translation.width,
                    vertical: value.translation.height
                ) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        navigation.move(direction)
                    }
                }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    dragOffset = .zero
                }
            }
    }

    // MARK: - Panes

    @ViewBuilder
    private func paneView(for pane: MusicPane, size: CGSize) -> some View {
        switch pane {
        case .player:
            PlayerPane()
        case .queue:
            QueuePane()
        case .favourites:
            FavouritesPane()
        case .library:
            LibraryPane()
        case .settings:
            SettingsPane()
        }
    }

    // MARK: - Bottom now playing bar (menu panes only)

    @ViewBuilder
    private var bottomNowPlayingBar: some View {
        if navigation.currentPane != .player, let song = model.player.currentSong {
            VStack {
                Spacer()
                CrossNowPlayingBar(song: song) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        navigation.currentPane = .player
                    }
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Player background gradient

/// 再生画面のアルバム由来の青緑系グラデーション。下部セーフエリアまで途切れず表示する。
private struct PlayerGradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.00, green: 0.01, blue: 0.04),
                Color(red: 0.00, green: 0.08, blue: 0.25),
                Color(red: 0.00, green: 0.26, blue: 0.58),
                Color(red: 0.24, green: 0.66, blue: 0.90),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            RadialGradient(
                colors: [.cyan.opacity(0.22), .clear],
                center: .center,
                startRadius: 40,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Player pane (centre)

private struct PlayerPane: View {
    @Environment(AppModel.self) private var model
    @State private var showLyrics = false

    var body: some View {
        GeometryReader { proxy in
            let artworkSide = min(proxy.size.width - 56, 340)
            VStack(spacing: 0) {
                Spacer(minLength: 8)

                if let song = model.player.currentSong {
                    topButtons(for: song)

                    Spacer(minLength: 12)

                    ArtworkImageView(
                        artworkId: song.artworkId,
                        urlString: model.artworkURL(for: song.artworkId),
                        cornerRadius: 16,
                        size: artworkSide
                    )
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

                    Spacer(minLength: 20)

                    VStack(spacing: 6) {
                        Text(song.displayTitle)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        Text(song.displayArtist)
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        if !song.album.isEmpty {
                            Text(song.displayAlbum)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)

                    Spacer(minLength: 18)

                    PlayerProgressSection()
                        .padding(.horizontal, 28)

                    Spacer(minLength: 16)

                    PlayerTransportSection()

                    Spacer(minLength: 28)
                } else {
                    Spacer()
                    emptyState
                    Spacer()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .padding(.top, 56)
        }
        .fullScreenCover(isPresented: $showLyrics) {
            if let song = model.player.currentSong {
                NowPlayingLyricsScreen(song: song, isPresented: $showLyrics)
                    .environment(model)
            }
        }
    }

    private func topButtons(for song: Song) -> some View {
        HStack {
            Button {
                showLyrics = true
            } label: {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(model.hasLocalLyricsFile(for: song.id) ? .white : .white.opacity(0.38))
            }
            .accessibilityLabel("歌詞を表示")

            Spacer()

            Text(song.fileType.isEmpty ? "" : song.fileType.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Button {
                model.toggleFavourite(songId: song.id)
            } label: {
                Image(systemName: model.isFavouriteSong(songId: song.id) ? "heart.fill" : "heart")
                    .foregroundStyle(model.isFavouriteSong(songId: song.id) ? .pink : .white.opacity(0.85))
            }
            .accessibilityLabel("お気に入り")
        }
        .font(.system(size: 18, weight: .semibold))
        .padding(.horizontal, 28)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text("再生中の曲はありません")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
            Text("下にスワイプしてライブラリから曲を選んでください")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

/// 進捗バー。位置/長さの高頻度更新をこのサブツリーに閉じ込める。
private struct PlayerProgressSection: View {
    @Environment(AppModel.self) private var model
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        let duration = max(model.player.durationSeconds, 0.001)
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : model.player.positionSeconds },
                    set: { scrubValue = $0 }
                ),
                in: 0 ... duration,
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        scrubValue = model.player.positionSeconds
                    } else {
                        isScrubbing = false
                        model.player.seek(to: scrubValue)
                    }
                }
            )
            .tint(.white)

            HStack {
                Text(Self.formatTime(isScrubbing ? scrubValue : model.player.positionSeconds))
                Spacer()
                Text(Self.formatTime(duration))
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? max(0, seconds) : 0
        let m = Int(safe) / 60
        let s = Int(safe) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}

/// トランスポート操作。再生状態の更新をこのサブツリーに閉じ込める。
private struct PlayerTransportSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 40) {
            Button {
                Task { await model.player.previous() }
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("前の曲")

            Button {
                model.player.togglePlayPause()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 78, height: 78)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.player.isPlaying ? "一時停止" : "再生")

            Button {
                Task { await model.player.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("次の曲")
        }
    }
}

// MARK: - Queue pane (left)

private struct QueuePane: View {
    @Environment(AppModel.self) private var model

    private var queue: [Song] { model.player.playbackQueue }

    var body: some View {
        PaneScaffold(title: "再生キュー") {
            if queue.isEmpty {
                PaneEmpty(text: "キューは空です。")
            } else {
                List {
                    ForEach(Array(queue.indices), id: \.self) { idx in
                        let song = queue[idx]
                        Button {
                            Task { await model.player.playQueueItem(at: idx) }
                        } label: {
                            HStack(spacing: 12) {
                                if idx == model.player.currentQueueIndex {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.cyan)
                                        .frame(width: 22)
                                } else {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 22)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(song.displayTitle)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.white)
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
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

// MARK: - Favourites pane (right)

private struct FavouritesPane: View {
    @Environment(AppModel.self) private var model

    private var songs: [Song] { model.favouriteSongsForPlayback() }

    var body: some View {
        PaneScaffold(title: "★ お気に入り") {
            if songs.isEmpty {
                PaneEmpty(text: "お気に入りはまだありません。再生画面のハートで追加できます。")
            } else {
                List {
                    ForEach(songs) { song in
                        Button {
                            let list = model.favouriteSongsForPlayback()
                            Task { await model.player.play(song, newQueue: list) }
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkImageView(
                                    artworkId: song.artworkId,
                                    urlString: model.artworkURL(for: song.artworkId),
                                    cornerRadius: 6,
                                    size: 44
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(song.displayTitle)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.white)
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
                                Label("解除", systemImage: "heart.slash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

// MARK: - Library pane (up) — non-scrolling menu; details open as sheets

private struct LibraryPane: View {
    @State private var showLocalLibrary = false

    private let tiles: [(title: String, symbol: String)] = [
        ("アルバム", "opticaldisc"),
        ("プレイリスト", "music.note.list"),
        ("全曲", "music.note"),
    ]

    var body: some View {
        PaneScaffold(title: "ライブラリ") {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                spacing: 14
            ) {
                ForEach(tiles, id: \.title) { tile in
                    Button {
                        showLocalLibrary = true
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: tile.symbol)
                                .font(.system(size: CrossPlayerLayout.libraryMenuIconSize, weight: .semibold))
                                .frame(height: 32)
                            Text(tile.title)
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: CrossPlayerLayout.libraryMenuItemMinHeight)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showLocalLibrary) {
            LocalLibrarySheet(isPresented: $showLocalLibrary)
        }
    }
}

/// `LocalLibraryScreen`（自前の NavigationStack を持つ）をシートで提示する薄いラッパー。
private struct LocalLibrarySheet: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool

    var body: some View {
        LocalLibraryScreen()
            .environment(model)
            .overlay(alignment: .topTrailing) {
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(12)
                }
            }
    }
}

// MARK: - Settings pane (down) — EQ + entries to server / remote (sheets)

private struct SettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var showEQEditor = false
    @State private var showServerSettings = false
    @State private var showRemoteLibrary = false
    @State private var showRemoteControl = false

    var body: some View {
        PaneScaffold(title: "設定") {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    equaliserCard
                    entriesCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showEQEditor) { EQBandEditorSheet().environment(model) }
        .sheet(isPresented: $showServerSettings) { SettingsScreen().environment(model) }
        .sheet(isPresented: $showRemoteLibrary) { RemoteLibraryScreen().environment(model) }
        .sheet(isPresented: $showRemoteControl) { RemoteControlScreen().environment(model) }
    }

    private var equaliserCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("イコライザー")
                .font(.headline)
                .foregroundStyle(.white)

            Toggle(
                "イコライザーを有効化",
                isOn: Binding(
                    get: { model.player.equaliserEnabled },
                    set: { model.player.setEqualiserEnabled($0) }
                )
            )
            .tint(.cyan)

            Menu {
                ForEach(GraphicEqualiserConfiguration.presetNamesOrdered, id: \.self) { name in
                    Button(name) { model.player.applyEqualiserPreset(named: name) }
                }
            } label: {
                HStack {
                    Text("プリセット")
                    Spacer()
                    Text(model.player.equaliserPresetDisplayName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .foregroundStyle(.white)
            }

            HStack {
                Text("プリアンプ")
                Slider(
                    value: Binding(
                        get: { Double(model.player.equaliserPreampDecibels) },
                        set: { model.player.setEqualiserPreampDecibels(Float($0)) }
                    ),
                    in: -24 ... 24
                )
                .tint(.cyan)
                .disabled(!model.player.equaliserEnabled)
                Text("\(Int(model.player.equaliserPreampDecibels)) dB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
            }
            .foregroundStyle(.white)

            Button {
                showEQEditor = true
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("バンドを調整")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }
                .foregroundStyle(.white)
                .padding(.vertical, 6)
            }

            Toggle(
                "ラウドネス正規化",
                isOn: Binding(
                    get: { model.player.normaliseEnabled },
                    set: {
                        model.player.normaliseEnabled = $0
                        model.player.refreshVolumeForCurrentSong()
                    }
                )
            )
            .tint(.cyan)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var entriesCard: some View {
        VStack(spacing: 0) {
            settingsRow("サーバー設定 / ペアリング", symbol: "server.rack") { showServerSettings = true }
            Divider().overlay(Color.white.opacity(0.12))
            settingsRow("Remote ライブラリ", symbol: "wifi") { showRemoteLibrary = true }
            Divider().overlay(Color.white.opacity(0.12))
            settingsRow("Remote コントロール", symbol: "tv") { showRemoteControl = true }
        }
        .padding(.horizontal, 16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func settingsRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 26)
                    .foregroundStyle(.cyan)
                Text(title)
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

/// 10 バンドの増減編集シート。
private struct EQBandEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0 ..< GraphicEqualiserConfiguration.bandCount, id: \.self) { i in
                        bandControl(index: i)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 20)
                Spacer()
            }
            .navigationTitle("イコライザー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("フラット") { model.player.resetEqualiserToFlat() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    private func bandControl(index: Int) -> some View {
        let db = Int(model.player.equaliserBandDecibels[index])
        let enabled = model.player.equaliserEnabled
        return VStack(spacing: 8) {
            Button {
                let current = model.player.equaliserBandDecibels[index]
                model.player.setEqualiserBand(index: index, decibels: min(24, current + 1))
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background(Color.cyan.opacity(enabled ? 0.18 : 0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)

            Text(db >= 0 ? "+\(db)" : "\(db)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(db == 0 ? .secondary : .primary)

            Text(freqLabel(index))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Button {
                let current = model.player.equaliserBandDecibels[index]
                model.player.setEqualiserBand(index: index, decibels: max(-24, current - 1))
            } label: {
                Image(systemName: "minus").font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background(Color.cyan.opacity(enabled ? 0.18 : 0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
        .frame(maxWidth: .infinity)
    }

    private func freqLabel(_ index: Int) -> String {
        let hz = GraphicEqualiserConfiguration.centreFrequenciesHz[index]
        if hz >= 1000 {
            let k = hz / 1000
            return k.rounded() == k ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz))"
    }
}

// MARK: - Shared pane chrome

/// メニュー系ペインの共通枠。上部に題名、下部に再生中バー分の余白を確保する。
private struct PaneScaffold<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.top, 56)
            content()
            Spacer(minLength: 0)
            Color.clear.frame(height: 72) // bottom now playing bar clearance
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct PaneEmpty: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Bottom now playing bar

private struct CrossNowPlayingBar: View {
    @Environment(AppModel.self) private var model
    let song: Song
    let onTapInfo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTapInfo) {
                HStack(spacing: 12) {
                    ArtworkImageView(
                        artworkId: song.artworkId,
                        urlString: model.artworkURL(for: song.artworkId),
                        cornerRadius: 8,
                        size: 40
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(song.displayArtist)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.player.togglePlayPause()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.player.isPlaying ? "一時停止" : "再生")

            Button {
                Task { await model.player.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("次の曲")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }
}
