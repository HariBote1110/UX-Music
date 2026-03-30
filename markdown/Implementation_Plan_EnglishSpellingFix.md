# Implementation Plan: UI用語の英式綴り（British English）統一

## 概要
`GEMINI.md` のルール（British English の使用）に基づき、アプリケーションのUIに存在する米式綴り（American English）の用語を特定し、英式綴りに統一します。

## 修正対象の特定
1.  **音量ノーマライズ機能のステータス表示**
    -   `analyzed` → `analysed`
    -   影響範囲: `src/renderer/js/features/normalize-view.js`, `src/renderer/styles/normalize-view.css`
2.  **その他の表示項目**
    -   `index.html` の `Analysed Queue` は既に英式であることを確認済み。
    -   `console.log` やデバッグメッセージ内の米式綴りの修正。
    -   ドキュメント（`requirement.md` 等）内の用語の修正。

## 修正手順
### 1. バージョン情報の更新
-   `src/renderer/js/core/bridge.js` のバージョンを `0.1.9-Beta-9d` から `0.1.9-Beta-9e` へ更新。
-   `markdown/requirement.md` のバージョンを `v0.1.9-Beta-9e` へ更新。

### 2. 「音量ノーマライズ」機能の修正
-   `src/renderer/js/features/normalize-view.js`:
    -   内部ステータス文字列 `'analyzed'` を `'analysed'` に変更。
    -   内部変数 `currentJob` の `'analyze'` を `'analyse'` に変更。
-   `src/renderer/styles/normalize-view.css`:
    -   `.status-analyzed` セレクタを `.status-analysed` に変更。

### 3. ドキュメントの修正
-   `markdown/requirement.md`:
    -   `Analyzer` を `Analyser` に修正。

## 完了条件
- [x] UI上で「音量ノーマライズ」実行後のステータスが `analysed` と表示されること。
- [x] ドキュメントやソースコード内の日本語以外の表示用英語が英式綴り（British English）に統一されていること。
- [x] `bridge.js` および `requirement.md` のバージョンが `0.1.9-Beta-9e` に更新されていること。
