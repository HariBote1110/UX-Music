# デスクトップ版: ビュースクロール構造とヘッダー統一 / グリッド密度設定

## 決定事項

### 1. `.view-scroll` 共通スクロールラッパー
Songs タブは元から `#music-list`（`flex-grow:1; overflow-y:auto`、`::after` で
`--footer-height` 分の余白）が実際のスクロール担当で、`.main-content` 自体は
スクロールしない構造だった。一方アルバム/アーティスト/For You/プレイリストの
各グリッドとアーティスト詳細画面は、グリッド要素に `overflow-y:auto` も
`flex-grow` も無いままコンテンツを直接 `.view-container` に流し込んでいたため、
実際には `.main-content`（`overflow-y:auto`）がスクロールし、絶対配置の
`.playback-bar` の背面までスクロールバーが突き抜けていた。

修正は Songs タブと同じ構造を共通クラス化: `.view-container`
(`display:flex; flex-direction:column; height:100%`) の直下に `.view-header`
（固定）と `.view-scroll`（`flex-grow:1; overflow-y:auto`、`::after` で
`--footer-height` 分の余白、スクロールバー装飾は `#music-list` 等と共通の
セレクタグループに統合）を並べ、グリッドや `<h2>アルバム</h2>` 等はすべて
`.view-scroll` の中に置く。アルバム詳細・プレイリスト詳細は元々
`#a-detail-list`/`#p-detail-list` が同じ構造で機能していたため無改修。

`.main-content` 自体は `overflow-y:auto` のまま残した（`overflow:hidden` へは
switch していない）。理由: `.view-scroll` 導入後は各ビューのコンテンツが
`.main-content` の高さにちょうど収まるため `.main-content` 側の実効スクロール
は発生せず、`overflow:hidden` にしても機能上は等価。一方 normalize-view /
quiz-view / lrc-editor-view / cd-rip-view / mtp-browser-view /
mtp-transfer-view など今回のオーナーシップ外のビューが `.main-content` の
スクロール依存を持っていないか全ては検証できなかったため、リスクを避けて
現状維持とした。

### 2. スクロール位置の park/restore 対象を修正
`.main-content` がスクロールしなくなったことで、`core/navigation.ts` の
`showView` 末尾と `features/park.ts` の `captureUIState`/`restoreFromPark` が
読み書きしていた `elements.mainContent.scrollTop` は常に `0` になってしまう
（Songs タブは元からこの問題を抱えていた可能性がある）。
`ui/view-renderer.ts` に `getActiveScrollElement()` を追加し
（`.view-scroll` → `#music-list` → `#a-detail-list` → `#p-detail-list` →
フォールバックで `mainContent` の優先順で検索）、navigation.ts / park.ts は
これ経由でスクロール位置を保存・復元するように変更した。
オーナーシップ外の2ファイルだが、スクロール構造を変えた以上ここを直さないと
駐機復帰後にスクロール位置が必ず先頭に戻る退行になるため修正した。

### 3. ヘッダー余白の統一
`h1` 単体（0px）/ `.view-header`（20px、旧プレイリストタブのみ）/
`.detail-header`（30px）とバラバラだったのを `--view-header-gap`（既定
20px、`base.css` の `:root` で定義）に統一。全5タブ（曲/アルバム/アーティスト
/For You/プレイリスト）が `.view-header` でラップされていることを
`js/ui/view-headers.test.ts` で回帰テストしている。

### 4. グリッド密度設定（compact/standard/large）
`--grid-item-min`（既定 160px）を `base.css` の `:root` に追加し、
`#album-grid,#playlist-grid,#artist-grid,.album-grid` の
`grid-template-columns: repeat(auto-fill, minmax(var(--grid-item-min), 1fr))`
がこれを参照する。設定値→px の純粋なマッピングと CSS 変数への反映・
`musicApi.saveSettings({ gridDensity })` への永続化を `js/ui/grid-density.ts`
に集約（`gridDensityToPx`はユニットテスト済み）。起動時の読み込みは
`js/utils/init-settings.ts`（オーナーシップ外）の既存 `loadRendererSettings()`
コールバックに `applyGridDensity(settings.gridDensity)` を1行追記するのみに
留めた。UI はアイコン無しの3セグメントコントロールで、アルバム/アーティスト/
プレイリストタブの `.view-header` 右側に配置（For You タブには付けていない
— 指示範囲外のため）。CSS 変数を書き換えるだけなので密度切替時の再描画は
不要。

### 5. For You タブの空状態・説明文・アートワーク刷新
`server/situation_playlists.go`（読み取りのみ、他エージェントが並行改修中）
の現行 JSON 形状は `{name, songs}`（バケットキーで map 化）だが、将来
`{id, title, description?, songs, artworks?}` に変わる計画のため、
`renderSituationView` は `title ?? name`・`description` 任意・`artworks` は
無ければ従来通り曲から導出、という両対応にした。空状態は単なる
`<div class="placeholder">` 文言から `.situation-empty-card`
（ライブラリが増える/曲を再生すると表示される旨の説明）に差し替え、
各カードは共通 `createPlaylistArtwork`（`js/ui/playlist-artwork.ts`）で
コラージュ描画し、`description` があれば `.playlist-description` として
タイトル下に表示する。

### 6. 詳細画面アートワークの角丸・プレイリストコラージュのクリップ
`.detail-art-img` に `border-radius:8px`（グリッドタイルと統一）と
`overflow:hidden` を追加（アーティスト詳細の丸型は従来通り
`.artist-detail-art-round` で上書き）。`.playlist-art-collage` は
サイズ指定を持たない `overflow:hidden` のみの薄いルールとして追加した
（detail-header 内の 200×200 固定サイズと、グリッドカード内の
`aspect-ratio:1/1` の両方の文脈で使い回されるため、幅や比率を書くと
`.detail-art-img` 側の固定サイズを CSS 詳細度の都合で上書きしてしまう）。

### 7. フッターのダークフェード
`.container` のマスクが `-webkit-mask-image` 95% / `mask-image` 85% と
プレフィックス間で食い違っており、サイドバーの `#open-settings-btn` まで
暗くなるほど広くフェードしていた。`--footer-height` を基準にした
`calc(100% - var(--footer-height) - 48px)` 〜
`calc(100% - var(--footer-height))` に統一し、再生バー直上 48px
（`--footer-fade-height`）だけをフェードさせるようにした。

### 8. ミュートアイコン
`assets/icons/mute.svg`（`public/` 側も同様）は Material の `volume_off` を
そのまま使っており、スラッシュ線で切り取りきれなかった音波アークの断片
（2つの小さい弧サブパス）が残ったまま描画され、ミュート中なのに音が出て
いるように見えていた。スピーカー本体＋斜線のみの単純な1グリフパスに置換。

## 実施したがオーナーシップ外だったファイル
- `js/core/navigation.ts` / `js/core/navigation.test.ts` / `js/features/park.ts`
  — スクロール位置保存先の修正（上記2番）。単なる import+1行の追記に収まらず、
  実質的な挙動修正だったため通常のコミットとして扱った。
- `js/core/settings-helpers.ts` — `RendererSettingsRead` に `gridDensity?: string`
  を1行追加。
- `js/utils/init-settings.ts` — `applyGridDensity` の import 1行 + 起動時コール
  1行のみ追記。

## 未対応・要フォローアップ
- `.main-content` の `overflow:hidden` 化は見送った（上記2番参照）。他ビュー
  側の担当エージェントが自分のビューで `.main-content` スクロールに依存して
  いないことを確認できれば、`overflow:hidden` へ切り替えて二重スクロール
  バーの可能性を完全に排除できる。
- グリッド密度コントロールは For You タブには付けていない（依頼範囲が
  album/artist/playlist のみだったため）。
