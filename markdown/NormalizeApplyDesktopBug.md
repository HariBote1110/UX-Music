# デスクトップ（Wails）ノーマライズ「適用」が無反応に見える問題

## 概要

Wails 版デスクトップアプリにおいて、ノーマライズ画面で **解析は成功するが「ノーマライズを適用」が効かない／何も起きないように見える** という報告が続いている。本稿は調査で触れた経路・仮説・試行した対策・**未解決である点**を記録する。

## 現象（ユーザー報告の整理）

- 「ノーマライズを適用」ボタン（`#normalize-apply-btn`）を押しても UI が進まない、ログにも目立った出力がないことがある。
- **上書きモード**でも **別フォルダ指定後**でも同様に「動かない」と報告された。
- 一方で **解析**は正しく動く、という前提が複数回ある。

## 関連実装の所在（調査の起点）

| 領域 | 主なファイル |
|------|----------------|
| フロント：ノーマライズ UI・ジョブ送信 | `src/renderer/js/features/normalize-view.js` |
| フロント：Electron/Wails 橋渡し | `src/renderer/js/core/env-setup.js` |
| コンポーネント HTML | `src/renderer/components/normalize.html` |
| スタイル（レイアウト・再生バー） | `src/renderer/styles/normalize-view.css`, `src/renderer/styles/layout.css` |
| Go：ジョブ開始・イベント送出 | `server/app_normalize.go`, `server/normalize_wire.go` |
| コンポーネント読込順 | `src/renderer/js/ui/component-loader.js`, `src/renderer/renderer.js`（`loadAllComponents` → `initNormalizeView`） |

## 試行した対策（時系列の要約）

以下はリポジトリに取り込まれた変更の方向性であり、**いずれも「問題完全解消」とは確認できていない**（ユーザー報告ベース）。

1. **Go：`NormalizeStartJob` のファイル行ペイロード解釈**  
   Wails 経由で `map[string]interface{}` にならない要素を捨ててジョブが 0 件になる懸念に対し、`json.Marshal` / `Unmarshal` で正規化、`gain` の型ゆれ、`path` / `filePath` 別名、`normalize-job-finished` にメタ付与など。

2. **フロント：`go.main` / `go.server` の `App` 橋渡し**  
   `NormalizeStartJob` が `go.main.App` に無い場合に `go.server.App` を補完。`send` / `invoke` 前に再実行。

3. **フロント：イベントペイロード**  
   `normalize-worker-result` で `id` と `path` の両方を扱い、行の照合を堅牢化。`totalCount` をステータス更新より前に確定。

4. **フロント：適用ボタンの `disabled` 条件**  
   「別フォルダ」で出力先未指定のときにボタンが `disabled` だとクリックが発火しないため、有効化してクリック時に検証・通知する変更。

5. **フロント：再生バーとクリックの競合**  
   `footer.playback-bar` がメイン列に重なる構造のため、`pointer-events` でバー透過・子のみヒットを試す変更。ノーマライズ表示時に `updateListSpacer()` を再実行。

6. **フロント：`success` / `Success` の両対応**  
   解析結果の成功判定の表記ゆれ対策。

## 有力だった仮説（いまも検証余地あり）

以下は**同時に成立しうる**ため、単一原因に決め打ちしない方がよい。

### A. UI 層：クリックがボタンに届いていない

- 再生バーや別オーバーレイの **ヒット領域**、**`disabled` のまま**、**`z-index` / マスク** などで、見た目のボタンと実際のターゲットがずれる。
- `pointer-events` 変更後も環境差（WebView 版、OS、ウィンドウサイズ）で再現する／しないが分かれる可能性。

### B. ロジック層：クリックは届くが早期 `return`

- `filesToNormalize` が空（選択・`status === 'analysed'` 不一致など）。
- `confirm()` がキャンセル扱いで送信前に止まる（ダイアログが背面に隠れている等）。

### C. ブリッジ層：`start-normalize-job` が Go に届いていない

- `window.go.*.App.NormalizeStartJob` が未定義・別オブジェクト。
- Wails の `Call` が返す **Promise の拒否**が握りつぶされ、サイレント失敗に見える。

### D. Go 層：ジョブ 0 件・イベント未着信

- ペイロード解釈後も `jobs` が空 → `normalize-worker-result` が飛ばず、進捗だけ中途半端。
- `EventsEmit` やコンテキストまわり（理論上は失敗時に `log.Fatalf` に近い挙動もあり得るが、経路依存）。

### E. フロント：イベントは届くが行にマップできない

- `id` / `path` と内部 `Map` のキー不一致でハンドラが **`return`** し、見た目が変わらない。

## 未解決であること（本ドキュメントの位置づけ）

現時点で、**「上書き／別フォルダのいずれでも確実に再現しない／再現しても根本原因が特定できていない」** 状態として記録する。  
以降の調査は、下記の **証拠ベース** で切り分けることを推奨する。

## 推奨される次の調査手順

1. **クリックが届いているか**  
   `normalize-view.js` の適用ハンドラの**先頭**に一時的に `console.log('[Normalize][Apply] click')` を入れ、DevTools で確認する。  
   - 出ない → DOM / `disabled` / オーバーレイ優先。  
   - 出る → 送信以降。

2. **`start-normalize-job` が送られているか**  
   `env-setup.js` の `send` 分岐で `start-normalize-job` 専用のログ（既存の `[Wails-Mock] send` を拡張でも可）を確認する。

3. **Go 側**  
   ターミナルで `[Normalize] NormalizeStartJob: no runnable jobs` の有無、`NormalizeStartJob` 先頭での `len(files)` / 正規化後のジョブ数ログを一時追加する。

4. **Wails イベント**  
   `normalize-worker-result` / `normalize-job-finished` を DevTools で購読し、ペイロードの `type`, `id`, `path`, `result` を生で確認する。

5. **最小再現**  
   ファイル 1 件・上書き・解析直後のみ、という手順を README 用に固定し、**動く環境 / 動かない環境**の差分（OS、ビルド `wails dev` vs `wails build`、画面解像度）を記録する。

## 関連コミット（参照用・履歴）

調査中に積み上げた修正は `git log` で `Normalize` / `normalise` / `normalize-view` / `playback-bar` 等をキーに辿るとよい。本ファイル作成時点では **ユーザー確認「解決」のコミットは無い**。

---

*本メモは「原因未確定のバグ」を後から追うためのシングルソースのドラフトである。確定した根本原因が分かったら、本ファイルを更新するか `markdown/issues.md` 等へ統合すること。*
