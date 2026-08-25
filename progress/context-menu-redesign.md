# コンテキストメニューの再設計

## Decision

- `ContextMenuItem`（`src/renderer/js/ui/utils.ts`）に `checked?`, `icon?`, `separator?`, `disabled?`, `shortcut?`, `danger?` を追加。既存の `label` / `type: 'separator'` / `action` / `enabled` / `submenu` はそのまま動く（後方互換）。
- 各項目は「先頭スロット（20px 固定幅）＋ラベル＋末尾スロット（ショートカット文字 or サブメニュー用シェブロン）」の3分割で描画する。先頭スロットは `checked`/`icon` の有無に関わらず常に生成するため、チェック有無で隣接項目とラベル開始位置がずれる問題（旧実装は `'✓ '` と `'   '` というテキスト接頭辞でチェックを表現しており、空白の折りたたみで見た目がずれていた）を構造的に解消した。
- チェックマークとサブメニューの矢印は `'✓'` / `'›'` のテキスト文字をやめ、inline SVG で描画する（`CHECK_ICON_SVG` / `CHEVRON_ICON_SVG`）。よく使う操作向けに `BUILTIN_ICONS`（play / queue-add / playlist-add / delete / info / download）を用意し、`icon: '<キー名>'` で参照できる。キーに一致しなければ渡した文字列をそのまま inline SVG として扱うフォールバックも持つ。

## サブメニューのホバー挙動

- 従来: `.context-menu-item` に `position: relative` が無く、`.context-menu--submenu { position: absolute; left: 100% }` は実際には最も近い `position` 祖先（`.context-menu` 自身、`position: fixed`）を基準に配置されていた。JS 側の `mouseenter` ハンドラで毎回 `left`/`right`/`top` を計算し直していたが、その基準がずれていたため、見た目上の項目とサブメニューの間に「実体のない隙間」ができ、そこにポインタが入ると `mouseleave` が即座に発火してサブメニューが閉じていた。
- 修正: `.context-menu-item` に `position: relative` を付与し、サブメニューが正しく親項目基準で配置されるようにした。加えて以下の二重の安全策を入れている。
  1. **CSS のオーバーラップ**: `.context-menu--submenu { left: calc(100% - 2px) }` で親項目に軽く食い込ませ、`.context-menu-item.has-submenu` に見えない橋渡し用パディング（`padding-right` + 相殺する負の `margin-right`）を付けて、項目の当たり判定を右に少し延長する。
  2. **クローズ遅延**: `mouseleave` で即座に閉じず `SUBMENU_CLOSE_DELAY_MS`（150ms）後に閉じるようにし、その間にサブメニュー自身へ `mouseenter` するとクローズをキャンセルする。サブメニューから `mouseleave` した場合は改めてクローズを予約する。
- サブメニューの配置計算（右開き/左開きの反転、下端はみ出し時の上方向オフセット）は `computeSubmenuPlacement()` という DOM に依存しない純粋関数へ切り出し、ビューポート内クランプのロジックを単体テストできるようにした（`src/renderer/js/ui/context-menu-item.test.ts`）。

## キーボード操作

- Escape で閉じる挙動は維持。加えて `showContextMenu()` 内でトップレベル項目（サブメニューは対象外、スコープを抑えるため）に対する ArrowUp/ArrowDown でのフォーカス移動と Enter での実行を追加した。フォーカス中の項目は `.context-menu-item--focused` クラスでホバーと同じ見た目になる。

## 呼び出し元の移行

- `column-config.ts`（列の表示/非表示切替）、`sidecar.ts`（サイドカー先デバイス選択）はテキスト接頭辞方式から `checked` フィールドへ移行。
- `list-renderer.ts`: 再生/プレイリストに追加/ライブラリから削除にアイコンを付け、削除の前に区切り線・`danger: true` を追加。
- `mtp-browser.ts`: ラベル内の絵文字接頭辞（`⬇️`/`🗑️`）を廃止し `icon: 'download'` / `icon: 'delete'` + `danger: true` に置き換え、区切り線を追加。
- `lyrics-manager.ts`: 編集系アクションと和訳系アクションの間に区切り線を追加。

## Constraints / Gotchas

- `grid-renderer.ts` も `showContextMenu` の呼び出し元だが、他エージェントが並行して編集中のため本タスクでは意図的に触れていない。新しい `ContextMenuItem` フィールドは後方互換なので、そちらのメニューは従来どおり動作する（アイコン等の追加は未対応のまま）。
- `theme-music-center.css` の `.context-menu` / `.context-menu-item` 上書きは角丸を潰すだけで、新しいスロット構造と衝突する指定は無かったため変更していない。
