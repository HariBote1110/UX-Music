# iPhone 歌詞ビューの Desktop parity 統一と NowPlaying サイドパネルのリスト行統一

## 決定

### 1. iPhone シンク歌詞モーションを共有プリミティブへ収束

`NowPlayingLyricsScreen.swift` の `NowPlayingSyncedLyricsScroll` は、古い独自移植
（0.3s / 0.015s step / easeOut / 近傍行ブラー / ハード 8%/70% リニアフェード）だった。
これを `Core/LyricsStageKit.swift` の共有プリミティブへ収束させ、UX Music Desktop の
フルスクリオン歌詞（`fullscreen-view.ts` / `components.css`）および iPad Sidecar 画面と
モーションを 1:1 で一致させた。

- レイアウト: `nowPlayingLyricsLineOffsets` → `SidecarLyricsLayout.tops(heights:baseIndex:paneHeight:)`。
  `baseIndex = lines.isEmpty ? 0 : min(max(0, activeIndex), lines.count - 1)`（Sidecar と同一）。
- アクティブ行判定: `LRCParser.activeLineIndex` → `SidecarLyricsMotionPolicy.activeIndex(in:at:)`。
  イントロ中（最初の行の timestamp 前）は `-1`（どの行もハイライトしない）で Desktop 準拠。
- モーション: 各行 `.animation(.timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.8).delay(staggerDelay(forDistance:)), value: y)`。
  ローカル定数 `motionDuration` / `delayStep` / `motionCurve` は削除。
- アクティブ行スケール: `SidecarLyricsMotionPolicy.activeLineScale`（1.091）、`anchor: .leading`。
  行の `.frame(width: paneWidth / 1.091, alignment: .leading)` でスケール後のオーバーフローを防止。
- エッジフェード: インライン `LinearGradient` マスク → `.mask(SidecarLyricsEdgeFade.gradient)`（じわっと溶けるマルチストップ）。
- 近傍行ブラー系（`blurNeighbourRadius` / `blurBase` / `blurStep` / `blurMax` / `blurFade` /
  `blurRadius(distance:)` / `.blur(radius:)`）を全廃。Desktop にブラーは無い。
- tick: 全体を包む `TimelineView(.periodic(by: 0.05))`（20回/s で `ForEach` を作り直す）を、
  安定 `@State` アンカー付き `TimelineView(.periodic(from:by: 0.2))` を `.background { }` に置き、
  `.task(id:)` 内で `SidecarActiveLineUpdatePolicy.shouldUpdate(...)` の時だけ `activeIndex` を書く方式へ。
- フォント: primary `.system(size: 28, weight: .bold, design: .rounded)`、非アクティブ opacity 0.45、
  アクティブは白 + `.shadow(color: .white.opacity(0.15), radius: 24)`。和訳サブ行は
  `.system(size: 20, weight: .bold, design: .rounded)` / `.white.opacity(0.5)` / block gap 4
  （`SidecarLyricsTranslationStyle` が `SidecarScreen.swift` に `private` のため 3 値をハードコードし
  `// Mirrors SidecarLyricsTranslationStyle` コメントを付与）。
- 不要になった自由関数 `nowPlayingLyricsFadeOpacity` / `nowPlayingLyricsLineOffsets` /
  `nowPlayingLyricsLineDelay` と対応テストを削除。`nowPlayingLyricsShouldAutoScroll` /
  `nowPlayingLyricsSeekTime` とそのテストは維持。

### 2. モバイル専用の手動ドラッグ・ピークは意図的な差分として維持

Desktop / Sidecar には無いが、iPhone では歌詞を指で少しずらして先を覗く操作が有用なため、
`DragGesture` / `manualDragOffset` / `liveDragTranslation` / `lastUserScrollAt` /
`scheduleAutoScrollResume()` / `nowPlayingLyricsShouldAutoScroll`（3秒 auto-resume）を維持。
`dragOffset = manualDragOffset + liveDragTranslation` を共有レイアウトの `y` に加算で重ねる
（旧実装が `nowPlayingLyricsLineOffsets` に重ねていたのと同じ）。タップ seek も維持。

### 3. 位置ソースはローカルプレイヤーのまま

`max(0, model.player.positionSeconds)`。iPad Sidecar 用のリモートフィールド
（`model.sidecarPosition` 等）へは切り替えない。あれは iPad Sidecar 画面専用。

### 4. 「次に再生」キュー／お気に入りパネルをライブラリ行スタイルへ

`NowPlayingView.swift` の `NowPlayingQueuePanel` / `NowPlayingFavouritesPanel` の独自行
（暗い角丸カード `RoundedRectangle(cornerRadius: 12).fill(Color(red:0.07,...))` の
`listRowBackground`、`.body.weight(.semibold)` / `.footnote`）を、アプリの他の全曲リストと
同じ `SongRowView` 系規約へ再ベース化。

- お気に入り: `SongRowView(song:artworkId:artworkURL:onTap:)` + `.modifier(LibraryListRowStyle())`。
  `contextMenu`（`WatchTransferSongMenuItem`）、trailing `swipeActions` のお気に入り解除、
  `onTap`（再生 + `withAnimation(nowPlayingPanelSpring) { page = .main }`）は維持。URL は
  `model.artworkURL(for:)`。
- キュー: 先頭の連番／`waveform`（現在行）インジケータを残し、アートワークは出さない
  （ユーザー決定）。`SongRowView` へは差し替えず、`SongRowView` と同じメトリクス・
  タイポグラフィで行本体を再構築: `.frame(height: SongRowMetrics.rowHeight)`、
  外側 `HStack(spacing: 12)`、インジケータは `width: SongRowMetrics.artworkSize`(48) の
  コンテナ、number は `.system(size: 13, weight: .medium, design: .monospaced)` /
  `.foregroundStyle(.secondary)`、title `.body`/`.primary`/`lineLimit(1)`、
  secondary `.subheadline`/`.secondary`/`lineLimit(1)`、VStack spacing 2。
  `.modifier(LibraryListRowStyle())` を適用し暗い角丸カードを撤去。`contextMenu`
  （WatchTransfer + destructive Remove from Queue）、`.onMove`、`editMode` の
  Reorder/Done ヘッダーボタンと `.environment(\.editMode, $editMode)` は維持。
- 両パネルのヘッダー `.padding(.horizontal, 20)` → `.padding(.horizontal, SongRowMetrics.horizontalInset)`(16)。
- `.listStyle(.plain)` / `.scrollContentBackground(.hidden)` / `.background(Color.black)` /
  bottom `swipeHint(...)` / 空状態プレースホルダは維持。`NowPlayingPlaybackSettingsPanel` は変更なし。

## 検討したが却下した案

- **キューも `SongRowView` へ丸ごと差し替え**: `SongRowView` はアートワーク 48pt を必ず出す。
  キューは連番／`waveform` インジケータを見せたい・アートワークは不要というユーザー決定に
  合わないため、行本体だけ `SongRowMetrics` / 同タイポで手組みした。
- **`animation` の `value:` を `y + dragOffset` にする（Sidecar と完全一致）**: Sidecar の
  `SidecarSyncedLyricsList` は `value: y`（純レイアウトオフセット）。モバイルはそこにドラッグ量を
  足すため、`value:` に合成値を渡すとドラッグ中も timing-curve（0.8s）で追従してラバーバンド化する。
  `value:` はレイアウト分の `y` に限定し、`dragOffset` は `.offset` 側だけに足すことで、
  ドラッグは即時・アクティブ行変化のみカスケードアニメ、という両立にした。
- **和訳サブ行の値を `SidecarLyricsTranslationStyle` から参照**: 同 enum は
  `SidecarScreen.swift` に `private`。ファイル横断で公開 API 化する変更はスコープ外なので、
  3 値（fontSize 20 / opacity 0.5 / blockGap 4）をコメント付きでハードコードした。
- **`activeIndex` を tick 毎に無条件で書く**: `ForEach` が 5回/s で再 diff する。
  `SidecarActiveLineUpdatePolicy.shouldUpdate` で実際の行変化時のみ書く方式にした（Sidecar と同じ）。

## 制約・ゴッチャ

- **シミュレータ検証は未実施**。外付け SSD `/Volumes/hp-512G-SSD` が未マウントで
  CoreSimulator が全滅（`Cannot allocate memory (POSIX 12)` の既知の症状）。ユニットテスト実行・
  スクリーンショットによる視覚検証はできていない。コンパイル検証のみ実施:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -scheme UX-Music-Mobile
  -project UX-Music-Mobile/UX-Music-Mobile.xcodeproj -destination 'generic/platform=iOS Simulator'
  build CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**。
  - なお `xcodebuild -target UX-Music-Mobile -sdk iphonesimulator26.5 build`（Xcode 26.5、
    プロジェクトメモリ記載のフォールバック）は、`UX-Music-Mobile` が `UX-Music-Watch` に
    明示依存しており、その asset catalog コンパイルが sim runtime を要求するため
    この SSD 未マウント環境では失敗する。scheme ビルド（各ターゲットが正しい SDK を使う）
    + `generic/platform=iOS Simulator` なら CoreSimulator デバイスセット無しで通る。
- モーション／レイアウトのロジックは既に `SidecarLayoutMotionTests.swift`（共有プリミティブ）で
  カバー済み。本タスクで新規の純関数は導入しておらず、テスト済み enum へのビュー合成の差し替えのため、
  Red ステップは「`NowPlayingLyricsLogicTests.swift` から削除ヘルパーのケースを除去 →
  ビルド／テストが通ることを確認」とした（作為的な失敗テストは作らない）。
- `LyricsLineHeightKey` PreferenceKey は引き続き必要（行ごとの実測高さを
  `SidecarLyricsLayout.tops` に渡すため）。doc コメントの `nowPlayingLyricsLineOffsets` 参照のみ
  `SidecarLyricsLayout.tops` へ更新。
- 歌詞カラムの水平インセットは、Sidecar 版が外側 `.padding(28)` を持つ HStack 内にあるのに対し
  iPhone 版は単体配置のため、`GeometryReader` に `.padding(.horizontal, 28)`（plain ブランチの
  `.padding(28)` に合わせた）を付けて `paneWidth` を内側幅にしている。
