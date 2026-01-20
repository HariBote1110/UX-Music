# Implementation Plan: Wails 移行 Phase 1

## 1. 事前準備
- [x] `package.json` のバージョンを `0.1.9-Beta-5s` に更新。
- [x] `git status` を確認し、クリーンな状態で開始する。

## 2. Wails プロジェクトの初期化
- [ ] 現在のディレクトリ構成を考慮し、Wails プロジェクトを構成。
- [ ] `wails.json` の作成と設定（`frontend:dir` を `src/renderer` に指定）。

## 3. Go バックエンドの統合（App 構造体）
- [ ] `src/go/app.go` を作成し、Wails バインディング用の `App` 構造体を定義。
- [ ] `src/go/main.go` の既存ロジックを `App` 構造体のメソッド（`HandleRequest` 相当または個別メソッド）へブリッジ。
- [ ] `src/go/main.go` を Wails の `wails.Run` を使用するように修正。

## 4. フロントエンドの疎通確認
- [ ] `wails dev` でアプリが起動し、Go 側のメソッドが呼び出せるかを確認するための簡単なテストコードをフロントエンドに追加。

## 5. 次のステップへの準備
- [ ] Electron 依存（ipcRenderer 等）の段階的な排除計画を策定。
