# Watch UI 刷新（3ページ構成）

## Decision
- 試作段階だった Watch アプリの UI を watchOS 純正 Music アプリに寄せて刷新（2026-08-08）。
- ページ構成は **ライブラリ ⇄ 再生中 ⇄ キュー&音量** の3ページ横ページング（`WatchPage` に `.queue` を追加）。
- ライブラリ: 自作の青カプセルトグル（Songs/Albums）を廃止し、`List` + `NavigationLink` の掘り下げ構成（「曲」「アルバム」の2行）に変更。watchOS ではセグメント切替よりネイティブな作法。
- 再生中: 60×60 の前景アートワークを廃止し、キャッシュ済みアートワークを**全面背景**＋暗色スクリムに。アートワークのデコードキャッシュ（0.5秒 tick での再デコード防止）・Crown シークの debounce・`isSyncingCrownProgrammatically` ガード・42mm 向け `ScrollView` は既存機構をそのまま維持。
- 音量: SwiftUI ネイティブの音量ビューが watchOS SDK に存在しないため、`WKInterfaceVolumeControl(origin: .local)` を `WKInterfaceObjectRepresentable` でラップ（`WatchQueueVolumeView.swift` 内 `SystemVolumeControl`）。`.local` は Watch 自身の出力（本アプリは iPhone 経由でなく Watch 単体再生のため）。
- キューページの行タップは**現在のキューを同位置から再生するだけ**で Now Playing へ自動遷移しない（ライブラリ行のみ遷移）。
- Watch の UI 文言を日本語に統一（iOS 側と揃える。`routeError` 含む）。

## Alternatives considered
- (a) Digital Crown を音量に割り当ててシークを別 UI へ移す → 却下。Crown シークは純正 Podcasts/Music と同じ標準操作で、質を下げたくない。
- (b) メニューから音量画面を出す → 却下。1 操作深くなる。
- (c) 3ページ目に音量＋キュー → **採用**。純正 Music の構成と同型で、既存のページスワイプ構造と整合。

## Constraints / Gotchas
- `WatchSongRow` は `selectedPage: Binding` 依存をやめ `onSelect` クロージャに一般化（キューページからの再利用のため。遷移するかは呼び出し側の責務）。
- 行スワイプ（`swipeActions`）はページスワイプと競合するため引き続き禁止。削除は長押しコンテキストメニュー。
- 新規ファイル `WatchQueueVolumeView.swift` は `project.pbxproj` へ手動登録（Watch ターゲットの Sources のみ。アプリ／テストターゲットには不要）。
- `WatchAudioPlayerService.playbackQueue` は `@Published` の複製ではなく computed passthrough — `queue` の変化は必ず `currentSong`/`isPlaying` の更新を伴うため再描画はそちらが駆動する。

## 追記 (2026-08-08): 実使用フィードバックによる調整
- **Digital Crown をシーク→音量に変更**（ユーザー判断）。当初の検討では (a)「Crown を音量へ」を却下して (c) を採用したが、実際に触った結果メイン画面の Crown は音量の方が良いとの結論に。シークは代替 UI へ移さず**廃止**（前後スキップのみ残る。プログレスバーは表示専用）。純正 Music の Now Playing と同じ役割分担になった。
- Crown フォーカスは `WKInterfaceVolumeControl.focus()`（watchOS 6.0+）を `Coordinator` から一度だけ呼ぶ方式。`SystemVolumeControl` に `autoFocusesCrown` パラメータを追加して共有部品化（キューページは false、Now Playing は true）。
- **シャッフル/リピートをデスクトップ版 SVG（`random.svg`/`repeat.svg`）で大型化**。SVG はアセットカタログに `preserves-vector-representation` + `template-rendering-intent: template` でそのまま取り込めた（`currentColor` ストロークでも問題なし。actool 警告ゼロ、Assets.car 内の実ピクセルまで検証済み）。「1曲リピート」はデスクトップに変種がないため、リピートアイコン＋小さな「1」バッジで表現。
- 未再生時の背景はデスクトップ既定アートワーク（`RemoteDefaultArtwork`）を再生時と同じスクリムで全面表示（ユーザー要望）。
