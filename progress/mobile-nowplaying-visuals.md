# UX Music Mobile: 再生画面のスワイプ被覆バグ修正と歌詞画面の環境光デザイン刷新

## 決定事項

### 1. サイドパネル被覆率（`nowPlayingSidePanelCoverage`）

- `NowPlayingView.swift` の座標系:
  - `NowPlayingAmbientBackground` は `.ignoresSafeArea(.all)` で画面全体（ステータスバー帯・
    ホームインジケータ帯を含む）に描画される。これは意図的な設計（コメント参照）で、
    ambient グラデーションを `.clipped()` パネルの外側に置くことでセーフエリアまで届かせている。
  - 一方 Queue / Favourites / PlaybackSettings パネルは `GeometryReader` の中（セーフエリア
    準拠の座標系）にあり、`.background(Color.black)` はセーフエリア外の帯には届かない。
  - 結果として、サイドパネル表示中〜スワイプ中に画面上下の帯だけ ambient グラデーションが
    「侵食」して見えるバグが発生していた。
- 修正: 純関数 `nowPlayingSidePanelCoverage(page:horizontalDrag:width:) -> CGFloat` を追加し、
  既存の `displayStripOffset`（ドラッグのラバーバンド込みオフセット）から
  `abs(offset + w) / w` を `[0, 1]` にクランプして算出する。
  - `page == .playbackSettings` は常に `1`（全画面オーバーレイのため）。
  - `width <= 1` は `0`（初期レイアウト未確定時の安全策）。
- `GeometryReader` 内の `ZStack(alignment: .top)` の最背面（ストリップより背面・
  full-screen ambient background より前面のレイヤーとして機能する）に
  `Color.black.opacity(coverage).ignoresSafeArea().allowsHitTesting(false)` を追加。
  ドラッグ追従とスプリングアニメは既存の `page` / `horizontalDrag` の状態変化にそのまま
  追従するため、被覆レイヤー側に個別のアニメーション定義は不要。
- テスト可能にするため `NowPlayingPage` / `stripBaseX` / `displayStripOffset` /
  `nowPlayingSidePanelCoverage` を `private` から `internal` に変更した
  （`UX-Music-MobileTests/NowPlayingCoverageTests.swift`）。

### 2. 歌詞画面（`NowPlayingLyricsScreen.swift`）の環境光デザイン刷新

- 背景共有: `NowPlayingAmbientBackground` / `nowPlayingFallbackAccent` /
  `NowPlayingNavIconButton` を `internal` 化し、`NowPlayingView.swift` から
  ファイル移動せずに再利用。`NowPlayingView` の `fullScreenCover` から
  `ambientPalette`（`@State`）を歌詞画面へ渡すことで、再生画面と同じ配色のまま
  遷移できる（アートワークからの再抽出待ちが発生しない）。
- コントラスト確保のため、ambient background の上に `Color.black.opacity(0.35)` を重ねた。
- 同期歌詞（LRC）: レイアウトジャンプを避けるため全行フォントサイズは 26pt 固定とし、
  アクティブ行は `weight: .bold` / 不透明・非アクティブ行は `weight: .semibold` /
  `opacity(0.35)` / `blur(radius: 0.8)` で差をつけた。
- エッジフェード: `ScrollView` に `.mask(LinearGradient(...))` を適用し、上12%・下18%を
  フェードアウト。フェード係数のロジック自体は純関数 `nowPlayingLyricsFadeOpacity(fraction:)`
  としてテスト化した（実際の `.mask` はグラデーション記述で同じ帯幅を再現している）。
- 上下スペーサーとして `geo.size.height * 0.35` を先頭・末尾に置き、最初/最後の行も
  画面中央に来られるようにした。
- 行タップでシーク: `model.player.seek(to:)`（既存 API、`NowPlayingProgressSection` の
  スクラバーと同じもの）を使用。シーク対象時刻決定は純関数 `nowPlayingLyricsSeekTime(for:)`
  としてテスト化。
- 自動スクロール一時停止: `DragGesture` でユーザースクロールを検知し `lastUserScrollAt`
  （`Date?`）を更新。`TimelineView` の 0.05 秒ごとの再描画で
  `context.date.timeIntervalSince(lastUserScrollAt)` を計算し、
  純関数 `nowPlayingLyricsShouldAutoScroll(secondsSinceLastUserScroll:)`
  （3秒未満なら自動追従を止める）で判定する。
- ナビゲーションバーを廃止し、`NowPlayingNavIconButton` による「×」の浮きボタンのみ
  右上に配置（`NowPlayingView` の閉じるボタンと統一感を持たせた）。

## 検討したが採用しなかった案

- アクティブ行を `scaleEffect` で拡大する案 → 不採用。フォントサイズを可変にすると
  LazyVStack の行高が変わり、スクロール位置がガタつく（レイアウトジャンプ）ため、
  サイズは全行固定にして weight / opacity / blur のみで強調した。

## 罠・非自明な制約

- `NowPlayingAmbientBackground` を `.ignoresSafeArea(.all)` で複数箇所に置く場合、
  必ず「どのパネルがセーフエリア準拠か」を意識すること。今回のバグはまさに
  「ambient background だけがセーフエリア外まで描画され、それを覆うはずのパネルが
  セーフエリア内にしか存在しない」というレイヤー構成の食い違いが原因だった。
- `@testable import` 越しにテストから触れるためには `private` ではなく最低でも
  `internal`（デフォルト）にする必要がある。今回変更した
  `NowPlayingPage` / `stripBaseX` / `displayStripOffset` /
  `nowPlayingSidePanelCoverage` / `nowPlayingFallbackAccent` /
  `NowPlayingAmbientBackground` / `NowPlayingNavIconButton` はすべてこの理由で
  アクセスレベルを変更している。
- 新規 Swift テストファイルは Xcode プロジェクトファイル
  （`UX-Music-Mobile.xcodeproj/project.pbxproj`）に
  `PBXBuildFile` / `PBXFileReference` / グループ内の参照 / `PBXSourcesBuildPhase`
  の4箇所へ手動登録しないとビルド対象に含まれない。
