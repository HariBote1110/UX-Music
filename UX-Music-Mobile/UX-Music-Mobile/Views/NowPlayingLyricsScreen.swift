import SwiftUI

/// Full-screen lyrics viewer (plain `.txt` or synced `.lrc` using `MusicPlayerService.positionSeconds`).
struct NowPlayingLyricsScreen: View {
    @Environment(AppModel.self) private var model
    let song: Song
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                lyricsBody
            }
            .navigationTitle("歌詞")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        isPresented = false
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: model.player.currentSong?.id) { _, newId in
            if newId != song.id {
                isPresented = false
            }
        }
    }

    @ViewBuilder
    private var lyricsBody: some View {
        if let mode = model.localLyricsDisplay(for: song.id) {
            switch mode {
            case .plain(let text):
                ScrollView {
                    Text(text)
                        .font(.system(size: 18, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                }
            case .synced(let lines):
                NowPlayingSyncedLyricsScroll(lines: lines)
            }
        } else {
            ContentUnavailableView {
                Label("歌詞がありません", systemImage: "text.page")
            } description: {
                Text("この曲は保存された歌詞ファイルがありません。リモートライブラリからダウンロードした曲は、デスクトップ側に歌詞がある場合に自動で取り込まれます。")
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding()
        }
    }
}

// MARK: - Synced (LRC) body

private struct NowPlayingSyncedLyricsScroll: View {
    @Environment(AppModel.self) private var model
    let lines: [LRCParser.TimedLine]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let position = max(0, model.player.positionSeconds)
            let active = LRCParser.activeLineIndex(in: lines, at: position)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 18, weight: index == active ? .semibold : .regular, design: .rounded))
                                .foregroundStyle(index == active ? Color.white : Color.white.opacity(0.42))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                }
                .onAppear {
                    guard active >= 0, active < lines.count else { return }
                    proxy.scrollTo(lines[active].id, anchor: .center)
                }
                .onChange(of: active) { _, newIndex in
                    guard newIndex >= 0, newIndex < lines.count else { return }
                    let target = lines[newIndex].id
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
    }
}
