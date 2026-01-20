# Implementation Plan: Wails 移行 Phase 1

## 1. 事前準備
- [x] `package.json` のバージョンを `0.1.9-Beta-5s` に更新。
- [x] `git status` を確認し、クリーンな状態で開始する。

## 2. Wails プロジェクトの初期化
- [x] 現在のディレクトリ構成を考慮し、Wails プロジェクトを構成（ルート配置）。
- [x] `wails.json` の作成と設定（`frontend:dir` を `src/renderer` に指定）。

## 3. Go バックエンドの統合（App 構造体）
- [x] `app.go` を作成し、Wails バインディング用の `App` 構造体を定義。
- [x] `main.go` の既存ロジックを `App` 構造体のメソッドへブリッジ（一部）。
- [x] `main.go` を Wails の `wails.Run` を使用するように修正。

## 4. フロントエンドの疎通確認
- [x] `wails build` (または dev) を試行し、フロントエンドから Go 側のメソッドが呼び出せることを確認。

## 5. 設定機能の移行とエラー解消
- [x] Wails `App` 構造体への `GetSettings` / `SaveSettings` 実装。
- [x] `bridge.js` の Wails 対応と `env-setup.js` による `TypeError` の解消。

## 6. 次のステップへの準備
- [ ] Electron 依存（ipcRenderer 等）の段階的な排除計画を策定。
