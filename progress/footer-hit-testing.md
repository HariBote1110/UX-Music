# フッター（.playback-bar）のクリックすり抜け修正

## 決定
- `src/renderer/styles/layout.css` の `.playback-bar` に付いていた `pointer-events: none` を `pointer-events: auto` に戻した。あわせて、個別に `pointer-events: auto` を上書きしていた6個の子セレクタ（`.footer-artwork-container` / `.playback-controls` / `.progress-container` / `.audio-info-container` / `.volume-container` / `.device-container`）は親が有効になったため削除した。
- 根本原因: フッターは `position: absolute; bottom: 20px; left: 20px; right: 20px; z-index: 1000` でメインコンテンツの上に重なっているが、当該ブロックの `pointer-events: none` により、6個のクラスタ以外の領域（`padding: 8px 24px` の余白、ぼかし背景、ボーダー、`box-shadow`、`justify-content: space-between` が作る隙間）には当たり判定が存在せず、クリックが背面の `.main-content` へそのまま突き抜けていた。
- 旧コメント（`/* 背面を透過させ、下のメイン列（ノーマライズの適用ボタン等）へクリックを届ける */`）が主張していた「意図的な透過」は、現在は根拠が失われている。`src/renderer/js/ui/ui.ts:23` がフッターの実測高さを `--footer-height` カスタムプロパティへ動的にセットしており、`normalize-view.css:6` / `cd-ripper.css:4` / `quiz-view.css:5` / `lrc-editor.css:4` / `mtp-browser.css:7` / `layout.css:76` / `views.css:84-99,1003-1010` の各ビューはこの値を使ってフッター分の余白をすでに確保している。つまりフッターの背面に本来クリックされるべきコントロール（ノーマライズの適用ボタン等）は現状存在せず、`pointer-events: none` は死んだワークアラウンドだった。
- 傍証として `src/renderer/styles/theme-music-center.css:19-57` の MusicCenter テーマは、`body.mc-theme .playback-bar { pointer-events: auto; }` と `body.mc-theme .playback-bar * { pointer-events: auto; }` によってこの問題をすでに個別に回避していた（デフォルトテーマ側の修正だけが漏れていた）。

## 検討した代替案
- mc-theme 側の `body.mc-theme .playback-bar` / `body.mc-theme .playback-bar *` の2ルールを、デフォルトテーマ修正後は冗長として削除する案を検討したが、見送った。理由: `src/renderer/styles/components.css:344` の `.audio-info-tooltip`（`opacity: 0; visibility: hidden; pointer-events: none;` の非表示ツールチップ、JS 側でホバー時にのみ `auto` へ切り替える想定）が `.audio-info-container` の子孫として `.playback-bar` 配下に存在する。もし mc-theme の `.playback-bar * { pointer-events: auto; }` を削除すると、mc-theme 環境ではこの種の「意図的に非表示中は無効化されている」子要素の `pointer-events: none` を打ち消す効果も失われる可能性があり、影響範囲を確証できなかったため据え置いた。

## 制約・注意点
- 今回の修正は `layout.css`（デフォルトテーマ）のみ。`theme-music-center.css` の該当2ルールは意図的に未変更（上記参照）。
- リグレッションテスト `src/renderer/js/ui/playback-bar-hit-testing.test.ts` は `layout.css` を直接読み込み、`.playback-bar` ブロックに `pointer-events: none` が存在しないこと・`pointer-events: auto` が明示されていることを正規表現で検証する。将来同じ理由で `none` が再導入された場合に検知できる。
- バージョンを `1.0.0-Beta-56a` → `1.0.0-Beta-56b` に更新（`src/renderer/package.json`）。ルート `package.json` や Go 側のバージョン定数は本リポジトリに存在しないため対象なし。
