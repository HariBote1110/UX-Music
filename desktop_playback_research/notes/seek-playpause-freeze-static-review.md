# Desktop シークバー停止 / 再生ボタン無反応 — 静的解析による原因候補

## 目的 / 仮説
Desktop（Wails）でシークバーが動かない・前の曲の位置に固定される・再生/一時停止ボタンが無反応になる間欠不具合の原因を特定する。本ノートは静的コードレビュー段階の仮説記録であり、実測・再現は未了。

## 環境
- ホスト: macOS (Darwin 25.5.0)、リポジトリ main @ 3b3e47e
- 対象: `src/renderer/js/features/player.ts`, `playback-manager.ts`, `youtube-embed-player.ts`, `src/renderer/js/ui/player-ui.ts`

## 手順
- 読み取り専用のコードレビュー（Sonnet サブエージェント2系統: UI層 / 再生パイプライン層）。

## 結果 — 原因候補（可能性順）

### A. ポーリングの巻き戻り防止ガードが曲送り時に誤発動（前の曲の位置に固定）
`player.ts:297-305`。連続再生の自動次曲送りでは `isPlaying` が true のまま切り替わり（`wasPlaying === true`）、`seek()` を経由しないため `recentSeek === false`。新曲の `pos≈0` が旧曲の `prevPos` より小さいためガード `pos+0.15 < prevPos` が成立し `nextPos = prevPos` に固定。新曲の実位置が旧位置に追いつくまでシークバーが前の曲の位置に張り付く。`playLocal`（`player.ts:759-777`）が `goState.currentTime` をリセットしないことが根本。「前の曲の位置で固定」の報告と完全一致。

### B. `isSeeking` フラグのスタック（シークバー完全停止＋再生ボタン無反応を同時説明）
`player-ui.ts:305-322`。`mouseup` が `progressBar` 要素自身にのみバインドされ `document` にない。つまみをバー外で離すと `mouseup` を取りこぼし `isSeeking` が true のまま永久残留。以後 `updateProgressBarLoop`（`player-ui.ts:270-293`）が即 return してシークバー停止、`updatePlaybackStateUI`（`:597-642`）もガードされ再生ボタン表示が更新されない。さらに `mousedown` 時の `pauseCurrent()` で実再生も止まったまま。同パターンが `lrc-editor.ts:824-838` にも存在。

### C. `queue-play-embed` の mount サイレント失敗で「空状態」凍結
`youtube-embed-player.ts:112-166` の `mountEmbedPlayer` は DOM 未構築・空URL・token競合時に例外なく false を返し、`playEmbed`（`player.ts:678`）→ `handleQueuePlayEmbedEvent`（`playback-manager.ts:788-790`）はリカバリ無しで放置。Go側は曲をアクティブ扱いだがどのバックエンドも再生しておらず、`goState` は前曲の最終値で凍結、`togglePlayPause` は Wails 分岐で実質 no-op。「前の曲の位置で停止＋ボタン完全無反応」を同時説明。

### D. `goPollInFlight` スタックによるポーリング恒久停止
`player.ts:240-347`。`AudioGetStatus()` のWailsバインディング呼び出しにタイムアウトが無く、park / native-queue-background の WebView 破棄・再生成と重なると Promise が永遠に未解決のまま `goPollInFlight` が true 固定 → `goState` が凍結。間欠性・park機能との相互作用として整合。

### E. その他（優先度低）
- `queue-play-embed` 多重発火が `playSongChain` を経由せず並行実行される競合（`playback-manager.ts:100-102`）。
- embed iframe の `reattachEmbedPlayer` によるリロード中のコマンド取りこぼし（`youtube-embed-player.ts:183-195`）。
- `resetPlaybackUI` が曲送りで呼ばれない（表示残留、`player-ui.ts:652-670`）。

## 結論
単一原因ではなく独立バグの複合と推定。通常の連続再生中の固定は A、シーク操作直後の全停止は B、embed（YouTube公式再生）絡みの完全無反応は C、park 併用時の凍結は D が対応する仮説。いずれも未検証（採否未確定）。

## 次の一手 / 未検証事項
1. A: 自動次曲送りで `pos < prevPos` ガードが発動するかログ実測（再現性最有力）。
2. B: つまみをウィンドウ外で離して `isSeeking` 残留を確認（`document` への mouseup バインドで修正可能）。
3. C: embed曲スキップ連打・ビュー遷移中の mount 失敗ログ追加。
4. D: park 復帰後に `goPollInFlight` の値を確認。
