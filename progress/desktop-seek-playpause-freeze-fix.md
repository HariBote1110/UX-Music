# Desktop シークバー停止 / 再生ボタン無反応の修正

## Decision
間欠不具合は独立バグ4本の複合と特定し（静的解析: `desktop_playback_research/notes/seek-playpause-freeze-static-review.md`）、それぞれ最小修正をTDDで実装した。

- **A. 曲送り時の巻き戻り防止ガード誤発動**: ガードを純粋関数 `shouldSuppressPollRewind()`（`player.ts`）へ抽出し、`pos <= 1.0` への落下は曲送りとみなしガード対象外に。加えて `playLocal` で `goState.currentTime/duration` を再生開始前に0リセット（多重防御）。
- **B. `isSeeking` スタック**: シークバーのポインタ解放（mouseup/pointerup/pointercancel）を `document` にバインドする `bindSeekBarDragHandlers()`（`player-ui.ts`）へ抽出。バー外・ウィンドウ外で離してもシークが完了し再生・進捗ループが復帰する。`lrc-editor.ts` の同型バグも `bindEditorSeekBarDragHandlers()` で同様に修正。
- **C. embed mount サイレント失敗**: `handleQueuePlayEmbedEvent`（`playback-manager.ts`）が失敗時に300msで1回リトライし、なお失敗ならエラーログ＋再生状態リセットで固着を防ぐ。
- **D. ポーリング無限ハング**: `withPollTimeout()`（3秒）で `AudioGetStatus` 系のWailsバインド呼び出しをラップし、WebView破棄中でも `goPollInFlight` が必ず解除されるようにした。

## Alternatives considered
- A はガード条件に「曲ID変化の検知」を組み込む案もあったが、ポーリング層は曲IDを持たず配線が増えるため、位置閾値（pos≤1.0）＋開始時リセットの二段構えを採用。
- B は `setPointerCapture` 全面移行も検討したが、既存の mousedown ベース実装との差分を最小化する document バインド方式を採用。

## Constraints / Gotchas
- ガードの本来の目的（非同期ポーリング応答の順序入れ替わりによる一瞬の巻き戻り吸収）は維持している。曲頭1秒以内への正当な巻き戻り抑制は効かなくなるが実害なし。
- テストは抽出した純粋関数/ハンドラ単位（`player-seek-guard.test.ts`, `player-poll-timeout.test.ts`, `playback-manager-embed-retry.test.ts`, `player-ui-seek.test.ts`, `lrc-editor-seek.test.ts`）。全スイート 440 テストグリーン。
- 実機での間欠症状の再現確認は未実施（静的解析ベースの修正）。再発時は `desktop_playback_research` の候補E（多重発火競合・iframe再アタッチ）を疑うこと。
