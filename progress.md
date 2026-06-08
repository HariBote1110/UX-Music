## 2026-06-08 — TXT専用歌詞同期の音源候補選択と実ライブラリ検証

### 実施内容
- Python fallback に `UX_MUSIC_LYRICS_SYNC_AUDIO_SOURCES=full|vocals|both` を追加
- `full` ではDemucsを通さず元音源を直接 faster-whisper へ渡すようにした
- `both` では元音源候補とボーカル候補をそれぞれTXT行へ整列し、参照LRCを使わない品質スコアで候補選択するようにした
- 結果JSONへ `audioSource` / `alignmentQualityScore` / `candidateScores` を追加

### 検証
- `python/.venv/bin/python -m pytest python/tests -m 'not heavy' -q` → `30 passed, 1 deselected`
- `/Users/yuki/doc/uxmusic` 5曲ベンチ（LRC時刻は答え合わせのみ、入力は時刻なしTXT相当、`base` / `full`）:
  - アムネシア: `MAE(after_tol)=0.734s`
  - PROMINENCE: `81.670s`
  - Lone Wolf: `58.186s`
  - main heroine: `93.846s`
  - Twilight: `28.689s`
- PROMINENCE / `vocals` / `base`: `auto=23.731s`, `ja=69.775s`, `auto-ja=28.219s`
- `/opt/homebrew/bin/speech align` は実行可能だったが、アムネシアのボーカル抽出音声+簡易行復元では `MAE(after_tol)=3.395s`

### 判断
- アムネシアはfull音源ASRで0.8秒級に到達した
- PROMINENCE / Synthion系は反復ブロックとASR欠落が大きく、現行の曲全体一括ASR→後段整列では0.8秒級に届かない
- 次の本命は、セクション分割・複数候補DP・歌詞反復ブロックの構造推定

### 仕様同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-12c` に更新
- `src/renderer/package.json` / `src/renderer/package-lock.json` のバージョンを `1.0.0-Beta-9c` に更新

## 2026-06-08 — Python fallback Stage3の未来ドリフト修復と0.8秒級同期検証

### 実施内容
- `stage3_align` に、後半の繰り返しフレーズへ大きく吸われた行を、飛ばされたASRセグメントへ時系列順で戻す未来ドリフト修復を追加
- 繰り返しブロック末尾の延長補正を、未来ドリフト修復と単調化の後にも再適用するよう調整
- `UX_MUSIC_SYNC_FORWARD_DRIFT_GAP_SECONDS`（既定 `75.0`）と `UX_MUSIC_SYNC_FORWARD_DRIFT_MAX_ROWS`（既定 `32`）を追加
- `speech` CLI / Qwen3 Forced Aligner は導入済みのまま、今回の実装はバックエンドAPI不要のローカルPython fallback側を改善

### 検証
- `cd python && .venv/bin/python -m pytest tests/ -m 'not heavy' -v`
- `IGNORE/` 実測:
  - アムネシア / `base`: 既存ベースライン `MAE(after_tol)=0.952s`、今回の揺れ込み再測では `17.536s`
  - アムネシア / `medium`: 後段補正のみの理論再計算で `MAE(after_tol)=0.737s`、実パイプライン再推論では `2.564s`
  - PROMINENCE / `base`: `123s`級の全体ドリフトから `20.562s` まで改善したが、採用精度には未達
  - Lone_Wolf / `base`: `109s`級の全体ドリフトから `24.243s` まで改善したが、採用精度には未達

### 判断
- アムネシアでは同一ASR結果への後段補正で0.8秒級に届く条件を確認したが、Demucs / faster-whisper の再推論揺れで実パイプラインの確定値は安定しなかった
- PROMINENCE / Lone_Wolf は破綻を大幅に縮めたものの、0.8秒級には届かない
- これ以上は曲全体一括整列ではなく、チャンク化・複数候補保持・VAD/ASRアンカーによるセクション単位アラインメントが必要と判断し、今回の試行はここで切り上げ

### 仕様同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-12b` に更新
- `src/renderer/package.json` / `src/renderer/package-lock.json` のバージョンを `1.0.0-Beta-9b` に更新

## 2026-06-08 — macOSローカル強制アラインメント経路を追加

### 実施内容
- Swift sidecar に `Qwen3 Forced Aligner` / `speech align` 互換 CLI を優先する経路を追加
- `speech align` の単語タイムスタンプ出力を解析し、元のTXT歌詞行へ戻すマッパを実装
- `UX_MUSIC_LYRICS_SYNC_ALIGNER=auto|qwen3|off`、`UX_MUSIC_LYRICS_SYNC_ALIGNER_BIN`、`UX_MUSIC_LYRICS_SYNC_ALIGNER_MODEL` を追加
- `auto` ではローカルalignerが利用可能な場合に優先し、失敗時は既存WhisperKit経路へフォールバック
- Swift純粋ロジックのテストを追加

### 検証
- `swift test --package-path swift/lyrics-sync`
- `go test ./internal/lyricssync`
- `go test ./...`
- `npm run typecheck`（`src/renderer`）
- `npm test`（`src/renderer`）

### 仕様同期
- `markdown/requirement.md` / `src/renderer/js/core/bridge.ts` のバージョンを `0.1.9-Beta-12a` に更新
- `src/renderer/package.json` / `src/renderer/package-lock.json` のバージョンを `1.0.0-Beta-9a` に更新

## 2026-05-28 — レビュー指摘順のセキュリティ・再生修正

### 実施内容
- Wear API に認証トークンを導入し、LAN 上の未認証アクセスを拒否
- `/safe-media/` をライブラリ登録済み曲だけに制限し、`/safe-artwork/` と data URL アートワーク読み込みを安全な解決関数へ統一
- プレイリスト名の traversal を拒否
- ノーマライズ表示のHTMLエスケープを追加
- `profile=fast` で Swift sidecar の軽量モデル選択を尊重
- Wails build で `lyrics-sync-swift` を `.app/Contents/Resources/bin` に同梱
- Wails 再生位置でスキップ統計を記録
- AudioGraph 切替時に EQ 設定を再適用
- `/safe-media/` URL の予約文字を segment ごとにエンコード

### 検証
- `go test ./...`
- `npm test -- --run`
- `npm run typecheck`
- `swift build -c release --package-path swift/lyrics-sync`

---

## 2026-05-27 — リファクタリング G2 / R3 / R5+G6 の判定

### 実施内容
- **G2 完了**: `GetSituationPlaylists` (86 行) を 30 行に短縮
  - `pickRecentlyAdded` / `pickMostPlayed` / `pickRandomPick` を `situation_playlists.go` に切り出し
  - TDD で 8 ケースのテスト (`situation_playlists_test.go`)
  - go test ./... 全パス
- **R3 / R5 / G6 スキップ**: 実コードを精査した結果、Explore エージェントの誤検出だった
  - R3 (querySelector キャッシュ): 対象は呼び出し頻度が低い、または getElementById で O(1)
  - R5 (mtp-browser.ts コメントアウト): 実際にはコメントアウトされたコードブロックなし
  - G6 (wearPairingURLFromParts インライン化): 2 箇所利用＋専用テスト有り。インライン化は逆効果

### 選定理由・判断の根拠
- G2 は本物の責務分離: 3 つの異なるセクション (最近追加・よく聴く・ランダム) を 1 関数に詰め込んでいたため、用途別の純関数化で単体テストが書け、本体側の見通しが圧倒的に改善
- 偽陽性の 3 つは「Don't add features, refactor, or introduce abstractions beyond what the task requires」(CLAUDE.md) の原則に従って積極的にスキップ。「やらないこと」も判断
- スキャン結果は実コードでの再検証必須という教訓

### 残課題・次のステップ
- 今回着手したスキャン候補は全て決着。新規スキャンを行うかは別途判断

---

## 2026-05-27 — fix: ノーマライズ適用が反応しないバグの修正

### 実施内容
- 症状: 解析後、エラー行を外して「ノーマライズを適用」をクリックしてもボタンは押せるが何も起きない
- 原因: 過去コミット e121036 で導入した「id 不一致時に path で照合」フォールバックと、ペイロード narrow 化が、TS 移行 (92d7544) でリグレッション
- 純関数 `findNormalizeFileForResult` / `toJobFilePayload` を `normalize-lookup.ts` に新設 (8 ケースの vitest)
- `normalize-view.ts` の handler と apply 送信箇所を置換

### 選定理由・判断の根拠
- Wails の JSON ブリッジで id 型がゆらぎ `Map.get(id)` が undefined を返すと、handler 冒頭の `if (!file) return` で結果が黙って捨てられていた
- backend (`app_normalize.go`) は既に `path` をイベントに乗せているので、renderer 側で活用するだけで復旧
- 同じ理由で送信時も renderer の余分なフィールド (currentLufs, selected 等) を載せず `{id, path, gain}` に絞り、ブリッジ越しの型強制リスクを下げた

### 残課題・次のステップ
- G2 (GetSituationPlaylists 分割), R3 (querySelector キャッシュ), R5+G6 (デッドコード) に着手

---

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
