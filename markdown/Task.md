# Task: Wails への移行 Phase 1 - プロジェクト初期化と基盤設計

## 概要
Electron から Wails への移行を開始します。Phase 1 では、Wails プロジェクトの初期化、既存の Go ロジック（`src/go`）の App 構造体への統合、およびレンダラー（`src/renderer`）を Wails のフロントエンドとして動作させるための基盤を構築します。

## 完了条件
- [x] `package.json` のバージョンが `0.1.9-Beta-5s` に更新されていること。
- [x] Wails `App` 構造体への `GetSettings` / `SaveSettings` メソッドの実装
- [x] `bridge.js` の Wails 対応（設定の読み書き）
- [x] フロントエンドの `settings` 関連の `TypeError` を解消（`env-setup.js` の強化）
- [x] `src/renderer` が Wails の `frontend` として機能するためのディレクトリ構成が完了していること。
- [x] フロントエンドから Go のメソッドを呼び出すサンプルが動作すること。
