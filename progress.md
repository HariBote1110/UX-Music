## 2026-05-27 — リファクタリング R2: runAutoSync の責務分離

### 実施内容
- スキャン結果のうち R1 (`setupLrcEditorListeners`) はエージェントの計測誤り（実際は 60 行・13 リスナー）と判明し、スキップ
- R2 (`runAutoSync` 117 行) から純関数 2 つを抽出
  - `validateAutoSyncPrereqs`: 4 種の事前検証
  - `applyAlignedTimestamps`: 整列タイムスタンプの正規化＋代入
- 新モジュール `src/renderer/js/features/lrc-auto-sync.ts` に切り出し
- TDD: 11 ケースの vitest を Red → Green → 本体置換、tsc も通過
- 本体は 117 → 103 行 (-14 行) かつ、検証ロジックがテスト可能に

### 選定理由・判断の根拠
- lrc-editor.ts はグローバル変数 28 個と DOM 直操作の塊で全体を一気にテスト化するのは非現実的
- 「DOM/グローバルに触らない純ロジック」だけを切り出してテスト網を張る方針が現実解
- R1 は本来「26 個並列」と報告されていたが実コードを精査して虚偽と判明、 CLAUDE.md「premature abstraction を避ける」方針に従い不要と判断

### 残課題・次のステップ
- 後続候補: G2 (GetSituationPlaylists 96 行の分割), R3 (querySelector キャッシュ), R5 (デッドコード削除)
- lrc-editor.ts には他にも純粋ロジック (payload 構築, result パース) が残るので将来的に同パターンで切り出し可能

---

## 2026-05-27 — リファクタリング G1: store ヘルパー導入

### 実施内容
- 全コードベースをスキャンし、デッドコード/複雑関数/重複/パフォーマンスの観点で候補をリストアップ
- 最重要候補 G1（`store.Instance.Load` の冗長パターン）に着手
- TDD で `store.LoadSlice` / `store.LoadMap` を新設
  - Red: `internal/store/store_test.go` を追加 (6 ケース)
  - Green: `internal/store/store.go` にヘルパー 2 関数を実装
  - Refactor: server/ 14 ファイル, internal/ 2 ファイルの呼び出し側を一括置換 (-126 行)
- `go test ./...` 全パス

### 選定理由・判断の根拠
- 31 箇所で「Load → nil チェック → `interface{}` キャスト」が機械的に繰り返されていた
- スライス型 (library, analysed-queue) とマップ型 (settings, playcounts, loudness) に分かれて型付け可能
- 型付きヘルパーで呼び出し側は 1 行化し、誤って nil をデリファレンスするバグも構造的に防げる
- 代替案: ジェネリクスを使った `Load[T]` も検討したが、JSON Unmarshal 後の型は限定的で、2 関数で十分簡潔と判断

### 残課題・次のステップ
- R1: `lrc-editor.ts` の `setupLrcEditorListeners` (134 行・26 連続 addEventListener) を分割
- R2: `lrc-editor.ts` の `runAutoSync` (118 行・ネスト 4 階層) の責務分離
- 後続候補: G2 (GetSituationPlaylists 分割), G3, R3 (querySelector キャッシュ), R5 (デッドコード削除)
